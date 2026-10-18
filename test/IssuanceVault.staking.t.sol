// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {ETFFactory} from "../src/ETFFactory.sol";
import {ETFShare} from "../src/ETFShare.sol";
import {IssuanceVault} from "../src/IssuanceVault.sol";
import {LeekStaking} from "../src/LeekStaking.sol";
import {ILeekStaking} from "../src/interfaces/ILeekStaking.sol";
import {MockMUSD} from "./mocks/MockMUSD.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";

/**
 * The vault's half of the staking mechanism.
 *
 * The properties here are the ones where a mistake moves money between two
 * groups of users: that a discount reaches only the trader who earned it, that
 * the reserve top-up is never the part that gets discounted away, that revenue
 * reaches stakers rather than the treasury once routing is on, and that an
 * unstaked period cannot strand a fee.
 */
contract IssuanceVaultStakingTest is Test {
    MockMUSD musd;
    MockMUSD mezo;
    IndexOracle oracle;
    ETFFactory factory;
    ETFShare share;
    IssuanceVault vault;
    LeekStaking staking;

    address admin = makeAddr("admin");
    address publisher = makeAddr("publisher");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint16 constant FEE_BPS = 50;
    uint16 constant RESERVE_SHARE_BPS = 5000;
    int256 constant PRICE = 200e8;
    uint256 constant ONE = 1e18;

    /// The oracle-independent holding period the staking contract enforces.
    uint256 constant COOLDOWN = 1 hours;

    function setUp() public {
        vm.warp(1_700_000_000);
        musd = new MockMUSD(18);
        mezo = new MockMUSD(18);
        oracle = new IndexOracle("GOLOGGLE / MUSD", 8, 2000, 1 hours, 30, 1 hours, 2000, admin, publisher, guardian);
        vm.prank(publisher);
        oracle.publish(PRICE);

        factory = new ETFFactory(IERC20(address(musd)), admin);
        vm.prank(admin);
        factory.registerIndex("GOLOGGLE", oracle, 1 hours, FEE_BPS, RESERVE_SHARE_BPS, 1_000_000e18, guardian, treasury);
        vm.prank(admin);
        (address shareAddress, address vaultAddress) = factory.deployETF("Gologgle Index", "GOLOGGLE");
        share = ETFShare(shareAddress);
        vault = IssuanceVault(vaultAddress);

        staking = new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), admin, COOLDOWN);

        LeekStaking.Tier[] memory tiers = new LeekStaking.Tier[](2);
        tiers[0] = LeekStaking.Tier(100 * ONE, 2_000); // 20% off
        tiers[1] = LeekStaking.Tier(1_000 * ONE, 5_000); // 50% off
        vm.startPrank(admin);
        staking.setTiers(tiers);
        vault.setStaking(ILeekStaking(address(staking)));
        vm.stopPrank();

        for (uint256 i = 0; i < 2; ++i) {
            address who = i == 0 ? alice : bob;
            musd.mint(who, 1_000_000e18);
            mezo.mint(who, 10_000 * ONE);
            vm.startPrank(who);
            musd.approve(address(vault), type(uint256).max);
            mezo.approve(address(staking), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.stake(amount);
    }

    /**
     * Stake and wait out the holding period.
     *
     * The discount and the revenue share are both gated on it, so a test
     * about either has to get past it first. The gate itself is tested in
     * test/LeekStaking.flashstake.t.sol, where it is the subject rather than
     * an obstacle.
     */
    function _stakeAndWait(address who, uint256 amount) internal {
        _stake(who, amount);
        skip(1 hours);
    }

    /* ---------------------------------------------------------- discounts */

    function test_withoutStakingTheFeeIsUnchanged() public {
        vm.prank(admin);
        vault.setStaking(ILeekStaking(address(0)));
        assertEq(vault.effectiveFeeBps(alice), FEE_BPS);
    }

    function test_aNonStakerPaysTheFullFeeAndCanStillBuy() public {
        assertEq(vault.effectiveFeeBps(alice), FEE_BPS);
        vm.prank(alice);
        uint256 shares = vault.buy(1_000e18, 0);
        // 0.5% fee, 200 per share: 995 / 200 = 4.975 shares.
        assertEq(shares, 4.975e18);
    }

    function test_aStakerPaysLess() public {
        _stakeAndWait(alice, 100 * ONE);
        assertEq(vault.effectiveFeeBps(alice), 40); // 20% off 50
        _stakeAndWait(alice, 900 * ONE);
        assertEq(vault.effectiveFeeBps(alice), 25); // 50% off 50
    }

    function test_theDiscountReachesOnlyTheTraderWhoEarnedIt() public {
        _stakeAndWait(alice, 1_000 * ONE);
        assertEq(vault.effectiveFeeBps(alice), 25);
        assertEq(vault.effectiveFeeBps(bob), FEE_BPS);

        vm.prank(alice);
        uint256 aliceShares = vault.buy(1_000e18, 0);
        vm.prank(bob);
        uint256 bobShares = vault.buy(1_000e18, 0);
        assertGt(aliceShares, bobShares, "the staker did not get more shares for the same MUSD");
    }

    function test_theVaultClampsADiscountEvenIfTheStakingContractDoesNot() public {
        // A staking contract that lies about its cap must not be able to zero
        // the fee, because part of the fee is the reserve top-up.
        LyingStaking liar = new LyingStaking();
        vm.prank(admin);
        vault.setStaking(ILeekStaking(address(liar)));
        // 10_000 bps claimed, clamped to 5_000: half of 50 is 25.
        assertEq(vault.effectiveFeeBps(alice), 25);
    }

    function test_aDiscountNeverEatsTheReserveTopUp() public {
        uint256 reservesBefore = vault.reserves();
        _stakeAndWait(alice, 1_000 * ONE); // the deepest discount
        vm.prank(alice);
        vault.buy(1_000e18, 0);
        // Half of the (discounted) fee still reaches reserves: 1000 * 25bps
        // = 2.5, half of which is 1.25.
        assertEq(vault.reserves() - reservesBefore, 1_000e18 - 2.5e18 + 1.25e18);
    }

    /* ------------------------------------------------------------ routing */

    function test_revenueReachesStakersInsteadOfTheTreasury() public {
        _stakeAndWait(bob, 100 * ONE);

        vm.prank(alice);
        vault.buy(1_000e18, 0);

        // Alice is not staked, so she paid the full 50 bps = 5 MUSD. Half to
        // reserves, half routed: 2.5 MUSD to Bob, and nothing to the treasury.
        assertEq(vault.feesAccrued(), 0, "revenue stayed with the treasury");
        assertEq(staking.pending(bob), 2.5e18);
    }

    function test_withNobodyStakedTheFeeStaysWithTheTreasury() public {
        assertEq(staking.totalSupply(), 0);
        vm.prank(alice);
        vault.buy(1_000e18, 0);
        // Not routed, not stranded: exactly the old behaviour.
        assertEq(vault.feesAccrued(), 2.5e18);
        assertEq(musd.balanceOf(address(staking)), 0);
    }

    function test_redeemRoutesRevenueToo() public {
        vm.prank(alice);
        uint256 shares = vault.buy(10_000e18, 0);
        _stakeAndWait(bob, 100 * ONE);

        vm.startPrank(alice);
        share.approve(address(vault), shares);
        vault.redeem(shares, 0);
        vm.stopPrank();

        assertGt(staking.pending(bob), 0, "redeeming produced no revenue for stakers");
    }

    function test_routingSurvivesTheStakersAllLeaving() public {
        _stakeAndWait(bob, 100 * ONE);
        vm.prank(alice);
        vault.buy(1_000e18, 0);

        vm.prank(bob);
        staking.unstake(100 * ONE);
        assertEq(staking.totalSupply(), 0);

        // The next trade must not revert on NoStakers.
        vm.prank(alice);
        vault.buy(1_000e18, 0);
        assertEq(vault.feesAccrued(), 2.5e18);
    }

    function test_onlyTheAdminPointsTheVaultAtAStakingContract() public {
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert();
        vault.setStaking(ILeekStaking(address(0)));
        assertTrue(vault.hasRole(role, admin));
    }

    /* ------------------------------------------------- one-transaction sell */

    function test_redeemWithPermitNeedsNoSeparateApproval() public {
        (address owner, uint256 key) = makeAddrAndKey("permitter");
        musd.mint(owner, 10_000e18);
        vm.startPrank(owner);
        musd.approve(address(vault), type(uint256).max);
        uint256 shares = vault.buy(10_000e18, 0);
        vm.stopPrank();

        assertEq(share.allowance(owner, address(vault)), 0, "the test is not proving anything");

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, shares, deadline));

        uint256 before = musd.balanceOf(owner);
        vm.prank(owner);
        uint256 out = vault.redeemWithPermit(shares, 0, deadline, v, r, s);

        assertEq(musd.balanceOf(owner) - before, out);
        assertEq(share.balanceOf(owner), 0);
        // The allowance the permit created was consumed, not left standing.
        assertEq(share.allowance(owner, address(vault)), 0);
    }

    function test_aReplayedPermitReverts() public {
        (address owner, uint256 key) = makeAddrAndKey("permitter");
        musd.mint(owner, 10_000e18);
        vm.startPrank(owner);
        musd.approve(address(vault), type(uint256).max);
        uint256 shares = vault.buy(10_000e18, 0);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, shares / 2, deadline));

        vm.prank(owner);
        vault.redeemWithPermit(shares / 2, 0, deadline, v, r, s);

        // The nonce is spent, so the same signature cannot sell the rest.
        vm.prank(owner);
        vm.expectRevert();
        vault.redeemWithPermit(shares / 2, 0, deadline, v, r, s);
    }

    function test_anExpiredPermitReverts() public {
        (address owner, uint256 key) = makeAddrAndKey("permitter");
        musd.mint(owner, 10_000e18);
        vm.startPrank(owner);
        musd.approve(address(vault), type(uint256).max);
        uint256 shares = vault.buy(10_000e18, 0);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, shares, deadline));
        vm.warp(deadline + 1);

        vm.prank(owner);
        vm.expectRevert();
        vault.redeemWithPermit(shares, 0, deadline, v, r, s);
    }

    function _permitDigest(address owner, uint256 value, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(vault),
                value,
                share.nonces(owner),
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", share.DOMAIN_SEPARATOR(), structHash));
    }

    /* --------------------------------------------------------------- fuzz */

    function testFuzz_aDiscountNeverTakesTheFeeBelowHalf(uint16 claimed) public {
        LyingStaking liar = new LyingStaking();
        liar.setDiscount(claimed);
        vm.prank(admin);
        vault.setStaking(ILeekStaking(address(liar)));

        uint16 effective = vault.effectiveFeeBps(alice);
        assertLe(effective, FEE_BPS);
        assertGe(effective, FEE_BPS / 2, "a fee below half the base starves the reserve top-up");
    }

    /* ------------------------------------------- the reward path is optional */

    function test_aRevertingStakingContractDoesNotStopTrading() public {
        // The finding three audit domains found independently: routing fee
        // revenue is a nice-to-have, letting a holder exit is not.
        HostileStaking hostile = new HostileStaking();
        vm.prank(admin);
        vault.setStaking(ILeekStaking(address(hostile)));

        // Buying works, at the full fee, and the revenue falls back to the
        // treasury rather than disappearing.
        assertEq(vault.effectiveFeeBps(alice), FEE_BPS, "a failed discount read should charge full fee");
        vm.prank(alice);
        uint256 shares = vault.buy(1_000e18, 0);
        assertGt(shares, 0);
        assertEq(vault.feesAccrued(), 2.5e18, "the fee was lost rather than accrued");

        // And redeeming works, which is the part that matters.
        vm.startPrank(alice);
        share.approve(address(vault), shares);
        uint256 out = vault.redeem(shares, 0);
        vm.stopPrank();
        assertGt(out, 0, "a holder could not exit");
    }

    function test_stakingPointedAtAnEoaIsRefusedOutright() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IssuanceVault.NotAContract.selector, alice));
        vault.setStaking(ILeekStaking(alice));
    }

    function test_theGuardianCanRestoreTradingNotOnlyStopIt() public {
        HostileStaking hostile = new HostileStaking();
        vm.prank(admin);
        vault.setStaking(ILeekStaking(address(hostile)));

        /* The unwire is only available while paused, so detaching staking is
           a declared incident rather than a standing power: one address
           holding both GUARDIAN and TREASURER could otherwise divert staker
           revenue to feesAccrued and withdraw it with nothing but a
           StakingSet(0) event to show. */
        vm.prank(guardian);
        vm.expectRevert(IssuanceVault.NotPaused.selector);
        vault.emergencyUnsetStaking();

        vm.startPrank(guardian);
        vault.pause();
        vault.emergencyUnsetStaking();
        vault.unpause();
        vm.stopPrank();
        assertEq(address(vault.staking()), address(0));

        vm.prank(alice);
        vault.buy(1_000e18, 0);
        assertEq(vault.feesAccrued(), 2.5e18);
    }

    function test_theAdminCannotUndoTheGuardiansRescueImmediately() public {
        /*
         * Inverted from what the code used to allow. `emergencyUnsetStaking`
         * was handed to the guardian as the remedy for a staking contract
         * that freezes trading - but `setStaking` had no timelock and no
         * cooldown, so the admin whose mistake caused the incident could
         * re-point the vault at the same contract in the very next block, as
         * often as the guardian unset it. The guardian's power was decorative.
         */
        vm.startPrank(guardian);
        vault.pause();
        vault.emergencyUnsetStaking();
        vault.unpause();
        vm.stopPrank();

        uint256 delay = vault.STAKING_RELOCK_DELAY();
        assertEq(vault.stakingLockedUntil(), block.timestamp + delay);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IssuanceVault.StakingLocked.selector, delay));
        vault.setStaking(ILeekStaking(address(staking)));

        // One second short of the window is still shut.
        vm.warp(block.timestamp + delay - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IssuanceVault.StakingLocked.selector, 1));
        vault.setStaking(ILeekStaking(address(staking)));

        // And open after it.
        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        vault.setStaking(ILeekStaking(address(staking)));
        assertEq(address(vault.staking()), address(staking));
    }

    function test_unsettingToZeroIsNeverLocked() public {
        /*
         * The lock must not be able to pin a hostile contract in place. Only
         * the direction that re-arms staking waits; the direction that
         * restores pre-staking behaviour is always available.
         */
        vm.startPrank(guardian);
        vault.pause();
        vault.emergencyUnsetStaking();
        vault.unpause();
        vm.stopPrank();

        vm.prank(admin);
        vault.setStaking(ILeekStaking(address(0)));
        assertEq(address(vault.staking()), address(0));
    }

    function test_theRegistryRefusesOneKeyAsGuardianAndTreasurer() public {
        /*
         * The invariant `emergencyUnsetStaking` is delegated on. One address
         * holding both roles can detach staking - stopping every staker's
         * rewards while trading looks normal - and then withdraw the fees
         * that accrue instead, leaving only a StakingSet(0) event behind.
         */
        ETFFactory f = new ETFFactory(IERC20(address(musd)), admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ETFFactory.SameHolder.selector, guardian));
        f.registerIndex("X", oracle, 1 hours, FEE_BPS, RESERVE_SHARE_BPS, 1_000_000e18, guardian, guardian);
    }

    function test_onlyTheGuardianCanUnwire() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.emergencyUnsetStaking();
    }

    function test_revenueThatCannotBeAccountedIsStrandedNotDoubleCounted() public {
        // A staking contract that accepts the MUSD but fails to account it.
        HalfHostileStaking half = new HalfHostileStaking();
        vm.prank(admin);
        vault.setStaking(ILeekStaking(address(half)));

        vm.prank(alice);
        vault.buy(1_000e18, 0);

        // The MUSD left the vault, so crediting feesAccrued too would count
        // it twice. It is at the staking contract and the next successful
        // distribution picks it up, because notifyReward measures its own
        // balance rather than trusting an argument.
        assertEq(vault.feesAccrued(), 0);
        assertEq(musd.balanceOf(address(half)), 2.5e18);
    }

    function test_buyRefusesAFeeChargingSettlementToken() public {
        // The symmetry with LeekStaking.stake, asserted. A vault that minted
        // shares against MUSD it did not receive would under-fund liabilities
        // from the first trade and compound the gap with volume.
        MockFeeToken fot = new MockFeeToken(100); // 1%
        IndexOracle o = new IndexOracle("X / MUSD", 8, 2000, 1 hours, 30, 1 hours, 2000, admin, publisher, guardian);
        vm.prank(publisher);
        o.publish(100e8);

        ETFFactory f = new ETFFactory(IERC20(address(fot)), admin);
        vm.startPrank(admin);
        f.registerIndex("X", o, 1 hours, FEE_BPS, RESERVE_SHARE_BPS, 1_000_000e18, guardian, treasury);
        (, address v) = f.deployETF("X Index", "X");
        vm.stopPrank();

        fot.mint(alice, 10_000e18);
        vm.startPrank(alice);
        fot.approve(v, type(uint256).max);
        vm.expectRevert();
        IssuanceVault(v).buy(1_000e18, 0);
        vm.stopPrank();
    }
}

/// Reverts on every call the vault makes into it.
contract HostileStaking {
    function discountBpsFor(address) external pure returns (uint16) {
        revert("no");
    }

    function totalSupply() external pure returns (uint256) {
        revert("no");
    }

    function notifyReward() external pure returns (uint256) {
        revert("no");
    }
}

/// Accepts MUSD and claims stakers exist, but cannot account for it.
contract HalfHostileStaking {
    function discountBpsFor(address) external pure returns (uint16) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 1;
    }

    function notifyReward() external pure returns (uint256) {
        revert("cannot account");
    }
}

/// A staking contract that ignores its own discount cap.
contract LyingStaking {
    uint16 private discount = 10_000;

    function setDiscount(uint16 next) external {
        discount = next;
    }

    function discountBpsFor(address) external view returns (uint16) {
        return discount;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function notifyReward() external pure returns (uint256) {
        return 0;
    }
}
