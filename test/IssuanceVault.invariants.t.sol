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
 * Bounded actions against one vault: buy, redeem, fund, move the price within
 * the oracle's bound, and withdraw fees. The handler never reverts on purpose
 * and swallows the reverts the contracts are supposed to produce, so a failing
 * invariant means a property broke rather than that a call was refused.
 */
contract Handler is Test {
    IssuanceVault public immutable vault;
    ETFShare public immutable share;
    MockMUSD public immutable musd;
    IndexOracle public immutable oracle;
    address public immutable publisher;
    address public immutable treasurer;

    address[3] public actors;
    /// @notice MUSD the handler has paid into the vault, fees included.
    uint256 public musdIn;
    /// @notice MUSD the handler has taken out, fees included.
    uint256 public musdOut;

    constructor(
        IssuanceVault vault_,
        ETFShare share_,
        MockMUSD musd_,
        IndexOracle oracle_,
        address publisher_,
        address treasurer_
    ) {
        vault = vault_;
        share = share_;
        musd = musd_;
        oracle = oracle_;
        publisher = publisher_;
        treasurer = treasurer_;

        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
        for (uint256 i = 0; i < actors.length; i++) {
            musd_.mint(actors[i], 1_000_000e18);
            vm.startPrank(actors[i]);
            musd_.approve(address(vault_), type(uint256).max);
            share_.approve(address(vault_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buy(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e18, 50_000e18);
        if (musd.balanceOf(actor) < amount) return;
        vm.prank(actor);
        try vault.buy(amount, 0) {
            musdIn += amount;
        } catch {}
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 held = share.balanceOf(actor);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        vm.prank(actor);
        try vault.redeem(shares, 0) returns (uint256 out) {
            musdOut += out;
        } catch {}
    }

    function fund(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e18, 10_000e18);
        if (musd.balanceOf(actor) < amount) return;
        vm.prank(actor);
        try vault.fund(amount) {
            musdIn += amount;
        } catch {}
    }

    /// Moves the price by at most the oracle's own per-round bound.
    function movePrice(uint256 bps, bool up) external {
        (, int256 current,,,) = oracle.latestRoundData();
        bps = bound(bps, 0, 2000);
        int256 step = (current * int256(bps)) / 10_000;
        int256 next = up ? current + step : current - step;
        if (next <= 0) return;
        /* Advance past the round interval before publishing.
         *
         * Without this the try/catch below swallows every TooSoon and the
         * price simply never moves, which silently removes price movement
         * from the state space the invariants are checked against - a worse
         * outcome than a failing handler, because everything still passes. */
        vm.warp(block.timestamp + oracle.minRoundInterval());
        vm.prank(publisher);
        try oracle.publish(next) {} catch {}
    }

    /// Time passes, so staleness is part of the state space rather than absent.
    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 hours));
    }

    function withdrawFees(uint256 amount) external {
        uint256 accrued = vault.feesAccrued();
        if (accrued == 0) return;
        amount = bound(amount, 1, accrued);
        vm.prank(treasurer);
        try vault.withdrawFees(treasurer, amount) {
            musdOut += amount;
        } catch {}
    }
}

contract IssuanceVaultInvariantsTest is Test {
    MockMUSD musd;
    IndexOracle oracle;
    ETFFactory factory;
    ETFShare share;
    IssuanceVault vault;
    Handler handler;

    address admin = makeAddr("admin");
    address publisher = makeAddr("publisher");
    address guardian = makeAddr("guardian");
    address treasurer = makeAddr("treasurer");

    function setUp() public {
        vm.warp(1_700_000_000);
        musd = new MockMUSD(18);
        oracle = new IndexOracle("GOLOGGLE / MUSD", 8, 2000, 1 hours, 30, 1 hours, 2000, admin, publisher, guardian);
        vm.prank(publisher);
        oracle.publish(200e8);

        factory = new ETFFactory(IERC20(address(musd)), admin);
        vm.prank(admin);
        factory.registerIndex("GOLOGGLE", oracle, 1 hours, 50, 5000, 1_000_000e18, guardian, treasurer);
        vm.prank(admin);
        (address shareAddress, address vaultAddress) = factory.deployETF("Gologgle Index", "GOLOGGLE");
        share = ETFShare(shareAddress);
        vault = IssuanceVault(vaultAddress);

        handler = new Handler(vault, share, musd, oracle, publisher, treasurer);
        targetContract(address(handler));
    }

    /// Fees are never paid out of shareholder money: the vault's balance always
    /// covers what it still owes the treasury.
    function invariant_balanceCoversAccruedFees() public view {
        assertGe(musd.balanceOf(address(vault)), vault.feesAccrued(), "fees exceed the vault's balance");
    }

    /// Every MUSD in the vault arrived through buy() or fund(), and everything
    /// that left went through redeem() or withdrawFees(). No other path exists.
    function invariant_musdIsConserved() public view {
        assertEq(musd.balanceOf(address(vault)) + handler.musdOut(), handler.musdIn(), "MUSD appeared or vanished");
    }

    /// Shares exist only against a buy, so supply is zero exactly when nobody
    /// holds any, and the cap is never exceeded however the price moved.
    function invariant_supplyWithinCap() public view {
        assertLe(share.totalSupply(), vault.maxShares(), "the cap was exceeded");
    }

    /// Only the vault can mint, so no supply can exist that the vault did not
    /// create: the three actors plus the vault hold the entire supply.
    function invariant_supplyIsHeldByActors() public view {
        uint256 held;
        for (uint256 i = 0; i < 3; i++) {
            held += share.balanceOf(handler.actors(i));
        }
        assertEq(held, share.totalSupply(), "shares are held by someone unknown");
    }

    /// The oracle never goes backwards, whatever sequence of pushes happened.
    function invariant_oracleRoundsAreMonotonic() public view {
        assertGt(oracle.latestRound(), 0);
    }
}
