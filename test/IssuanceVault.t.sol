// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {ETFFactory} from "../src/ETFFactory.sol";
import {ETFShare} from "../src/ETFShare.sol";
import {IssuanceVault} from "../src/IssuanceVault.sol";
import {MockMUSD} from "./mocks/MockMUSD.sol";

/**
 * The properties that decide whether this thing is honest: that buying and
 * redeeming price from the oracle and nowhere else, that a stale or broken
 * feed stops both, that fees are taken from the right side of the trade and
 * never from shareholder reserves, that the cap bounds exposure, and that a
 * redemption the vault cannot fund reverts with both numbers rather than
 * paying out whatever happens to be left.
 */
contract IssuanceVaultTest is Test {
    MockMUSD musd;
    IndexOracle oracle;
    ETFFactory factory;
    ETFShare share;
    IssuanceVault vault;

    address admin = makeAddr("admin");
    address publisher = makeAddr("publisher");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    uint8 constant MUSD_DECIMALS = 18;
    uint8 constant FEED_DECIMALS = 8;
    uint32 constant STALENESS = 1 hours;
    /// Seconds the oracle requires between rounds. See IndexOracle.
    uint32 constant MIN_ROUND_INTERVAL = 30 seconds;
    uint16 constant FEE_BPS = 50; // 0.5%
    /* Half of every fee stays in reserves: the funded backstop (H-1a). 50% in
       tests so both halves of the split are non-zero and a rounding error in
       either direction shows up. */
    uint16 constant RESERVE_SHARE_BPS = 5000;
    uint256 constant CAP = 1_000_000e18;
    int256 constant PRICE = 200e8; // 200 MUSD per share

    function setUp() public {
        vm.warp(1_700_000_000);
        musd = new MockMUSD(MUSD_DECIMALS);
        oracle = new IndexOracle("GOLOGGLE / MUSD", FEED_DECIMALS, 2000, STALENESS, MIN_ROUND_INTERVAL, admin, publisher, guardian);
        vm.prank(publisher);
        oracle.publish(PRICE);

        factory = new ETFFactory(IERC20(address(musd)), admin);
        vm.prank(admin);
        factory.registerIndex("GOLOGGLE", oracle, STALENESS, FEE_BPS, RESERVE_SHARE_BPS, CAP, guardian, treasury);
        vm.prank(admin);
        (address shareAddress, address vaultAddress) = factory.deployETF("Gologgle Index", "GOLOGGLE");
        share = ETFShare(shareAddress);
        vault = IssuanceVault(vaultAddress);

        musd.mint(alice, 1_000_000e18);
        musd.mint(bob, 1_000_000e18);
        vm.prank(alice);
        musd.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        musd.approve(address(vault), type(uint256).max);
    }

    /* --------------------------------------------------------- the factory */

    function test_rolesAreSeparateOnTheDeployedPair() public view {
        // Three holders, named in the registry: the admin tunes parameters,
        // the guardian can only stop the market, the treasurer can only move
        // fees. No one key does all three.
        assertTrue(vault.hasRole(vault.GUARDIAN_ROLE(), guardian));
        assertFalse(vault.hasRole(vault.GUARDIAN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.TREASURER_ROLE(), treasury));
        assertFalse(vault.hasRole(vault.TREASURER_ROLE(), admin));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), guardian));
    }

    function test_factoryFreezesConfigAndKeepsNoPower() public view {
        // The whole reason deployETF takes two strings: everything else is here.
        ETFFactory.IndexConfig memory config = factory.configFor("GOLOGGLE");
        assertEq(address(config.oracle), address(oracle));
        assertEq(config.feeBps, FEE_BPS);
        assertEq(config.maxShares, CAP);
        assertTrue(config.registered);

        // The factory hands administration over and keeps none.
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(share.hasRole(share.DEFAULT_ADMIN_ROLE(), admin));
        // Only the vault may mint or burn shares.
        assertTrue(share.hasRole(share.MINTER_ROLE(), address(vault)));
        assertFalse(share.hasRole(share.MINTER_ROLE(), admin));
    }

    function test_factoryRefusesUnregisteredAndDuplicate() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ETFFactory.NotRegistered.selector, "AMEZON"));
        factory.deployETF("Amezon Index", "AMEZON");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ETFFactory.AlreadyDeployed.selector, "GOLOGGLE"));
        factory.deployETF("Gologgle Index", "GOLOGGLE");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ETFFactory.AlreadyRegistered.selector, "GOLOGGLE"));
        factory.registerIndex("GOLOGGLE", oracle, STALENESS, FEE_BPS, RESERVE_SHARE_BPS, CAP, guardian, treasury);
    }

    function test_onlyAdminRegisters() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.registerIndex("AMEZON", oracle, STALENESS, FEE_BPS, RESERVE_SHARE_BPS, CAP, guardian, treasury);
    }

    /* ------------------------------------------------------------- pricing */

    function test_priceScalesFeedDecimalsToTokenDecimals() public view {
        // 200e8 at 8 feed decimals, against an 18-decimal token, is 200e18.
        assertEq(vault.price(), 200e18);
        assertEq(vault.oracleDecimals(), FEED_DECIMALS);
        assertEq(vault.musdDecimals(), MUSD_DECIMALS);
    }

    function test_priceRefusesStaleAndIncompleteFeeds() public {
        vm.warp(block.timestamp + STALENESS + 1);
        vm.expectRevert();
        vault.price();

        // A fresh round brings it back.
        vm.prank(publisher);
        oracle.publish(PRICE);
        assertEq(vault.price(), 200e18);
    }

    function test_buyAndRedeemRefusedWhenFeedIsStale() public {
        vm.warp(block.timestamp + STALENESS + 1);
        vm.prank(alice);
        vm.expectRevert();
        vault.buy(1000e18, 0);
    }

    /* ---------------------------------------------------------------- buying */

    function test_buyMintsAtOraclePriceAndTakesFee() public {
        uint256 spend = 1000e18;
        uint256 expectedFee = (spend * FEE_BPS) / 10_000; // 5 MUSD
        uint256 expectedShares = ((spend - expectedFee) * 1e18) / 200e18; // 4.975 shares

        vm.prank(alice);
        uint256 got = vault.buy(spend, expectedShares);

        assertEq(got, expectedShares);
        assertEq(share.balanceOf(alice), expectedShares);
        // Half the fee is the treasury's and half stayed in reserves, so the
        // backstop grows on every trade without anyone choosing to be generous.
        assertEq(vault.feesAccrued(), expectedFee / 2);
        assertEq(vault.reserves(), spend - expectedFee / 2);
        assertEq(musd.balanceOf(address(vault)), spend);
    }

    function test_buyRespectsSlippageAndCap() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IssuanceVault.Slippage.selector, 4.975e18, 5e18));
        vault.buy(1000e18, 5e18);

        vm.prank(admin);
        vault.setMaxShares(1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IssuanceVault.CapExceeded.selector, 4.975e18, 1e18));
        vault.buy(1000e18, 0);
    }

    function test_buyRejectsZero() public {
        vm.prank(alice);
        vm.expectRevert(IssuanceVault.ZeroAmount.selector);
        vault.buy(0, 0);

        // Too little to mint a single wei of share at this price.
        vm.prank(alice);
        vm.expectRevert(IssuanceVault.ZeroAmount.selector);
        vault.buy(1, 0);
    }

    /* ------------------------------------------------------------- redeeming */

    function test_redeemBurnsAndPays() public {
        vm.prank(alice);
        uint256 shares = vault.buy(1000e18, 0);

        vm.prank(alice);
        share.approve(address(vault), shares);
        uint256 before = musd.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, 0);

        assertEq(share.balanceOf(alice), 0, "shares were not burned");
        assertEq(share.totalSupply(), 0);
        assertEq(musd.balanceOf(alice), before + out);
        // Two fees paid, one each way, and the user is down exactly those.
        assertEq(out, 995e18 - (995e18 * uint256(FEE_BPS)) / 10_000);
    }

    function test_redeemNeedsAnApproval() public {
        vm.prank(alice);
        uint256 shares = vault.buy(1000e18, 0);
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientAllowance
        vault.redeem(shares, 0);
    }

    /**
     * The honest failure mode of a synthetic: the index rises, so what is owed
     * exceeds what was paid in, and redemption reverts naming both numbers
     * rather than paying out part of someone else's money.
     */
    function test_redeemRevertsWhenReservesAreShort() public {
        vm.prank(alice);
        uint256 shares = vault.buy(1000e18, 0);

        // +20% in one round, which the oracle's bound allows.
        vm.warp(block.timestamp + MIN_ROUND_INTERVAL);
        vm.prank(publisher);
        oracle.publish(240e8);

        vm.prank(alice);
        share.approve(address(vault), shares);
        uint256 owed = (shares * 240e18) / 1e18;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IssuanceVault.InsufficientReserves.selector, owed, vault.reserves())
        );
        vault.redeem(shares, 0);

        // The backstop is what makes them whole, and anyone may fund it.
        musd.mint(treasury, 1000e18);
        vm.startPrank(treasury);
        musd.approve(address(vault), 1000e18);
        vault.fund(1000e18);
        vm.stopPrank();

        vm.prank(alice);
        uint256 out = vault.redeem(shares, 0);
        assertGt(out, 0);
    }

    function test_liabilitiesAndReservesAreVisible() public {
        vm.prank(alice);
        vault.buy(1000e18, 0);
        // The reserve share is what makes a fresh buy over-covered rather than
        // exactly covered: liabilities are the net spend, reserves are that
        // plus the half of the fee that stayed behind.
        assertEq(vault.liabilities(), 995e18);
        assertEq(vault.reserves(), 997.5e18);
        assertGt(vault.coverageBps(), 10_000, "a buy must not leave coverage short");

        vm.warp(block.timestamp + MIN_ROUND_INTERVAL);
        vm.prank(publisher);
        oracle.publish(240e8);
        assertGt(vault.liabilities(), vault.reserves(), "a rally must show as a shortfall");
    }

    /* ------------------------------------------------------------------ fees */

    function test_onlyTreasurerWithdrawsAndOnlyFees() public {
        vm.prank(alice);
        vault.buy(1000e18, 0);
        uint256 fees = vault.feesAccrued();

        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawFees(alice, fees);

        // Not a wei more than the fee pot, whatever the balance says.
        vm.prank(treasury);
        vm.expectRevert(IssuanceVault.ZeroAmount.selector);
        vault.withdrawFees(treasury, fees + 1);

        vm.prank(treasury);
        vault.withdrawFees(treasury, fees);
        assertEq(musd.balanceOf(treasury), fees);
        assertEq(vault.feesAccrued(), 0);
        // Shareholder reserves untouched by the withdrawal: the fee pot and
        // the reserves are two pots inside one balance.
        assertEq(vault.reserves(), 1000e18 - fees);
    }

    function test_feeCeilingIsEnforced() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IssuanceVault.FeeTooHigh.selector, uint16(501)));
        vault.setFeeBps(501);
    }

    /* --------------------------------------------------------------- pausing */

    function test_guardianHaltsBothDirections() public {
        vm.prank(alice);
        uint256 shares = vault.buy(1000e18, 0);
        vm.prank(guardian);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(IssuanceVault.VaultPaused.selector);
        vault.buy(1e18, 0);

        vm.prank(alice);
        share.approve(address(vault), shares);
        vm.prank(alice);
        vm.expectRevert(IssuanceVault.VaultPaused.selector);
        vault.redeem(shares, 0);
    }

    /* ------------------------------------------------------------------ fuzz */

    /// Buying then immediately redeeming must never profit the user: fees are
    /// the house's edge, and any round trip that gained would be a mint bug.
    function testFuzz_roundTripNeverProfits(uint256 spend) public {
        spend = bound(spend, 1e18, 100_000e18);
        uint256 before = musd.balanceOf(alice);

        vm.prank(alice);
        uint256 shares = vault.buy(spend, 0);
        vm.prank(alice);
        share.approve(address(vault), shares);
        vm.prank(alice);
        vault.redeem(shares, 0);

        assertLe(musd.balanceOf(alice), before, "a round trip gained MUSD");
    }

    /// Whatever the price, shares minted are the net spend divided by it, and
    /// the vault's MUSD equals everything paid in.
    function testFuzz_mintMathFollowsThePrice(int256 newPrice, uint256 spend) public {
        newPrice = bound(newPrice, 1e8, 1_000e8);
        spend = bound(spend, 1e18, 10_000e18);
        // Reach the price in bounded steps the oracle will accept.
        _walkPriceTo(newPrice);

        uint256 p = vault.price();
        uint256 fee = (spend * FEE_BPS) / 10_000;
        uint256 expected = ((spend - fee) * 1e18) / p;
        vm.assume(expected > 0);

        vm.prank(alice);
        uint256 got = vault.buy(spend, 0);
        assertEq(got, expected);
        assertEq(musd.balanceOf(address(vault)), spend);
    }

    function _walkPriceTo(int256 target) internal {
        (, int256 current,,,) = oracle.latestRoundData();
        while (current != target) {
            int256 maxStep = (current * 2000) / 10_000; // the oracle's 20% bound
            int256 next;
            if (target > current) {
                next = target - current > maxStep ? current + maxStep : target;
            } else {
                next = current - target > maxStep ? current - maxStep : target;
            }
            // The oracle requires time between rounds now, so a ratchet is
            // a sequence in time rather than a burst in one block.
            vm.warp(block.timestamp + MIN_ROUND_INTERVAL);
            vm.prank(publisher);
            oracle.publish(next);
            current = next;
        }
    }
}
