// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ETFShare} from "./ETFShare.sol";

/**
 * @title IssuanceVault
 * @notice Buys and redeems one index's shares against MUSD, at the oracle price.
 *
 * @dev **Read this before using it for anything real.**
 *
 *      This is a *synthetic* issuer, not an ERC-4626 vault, and the difference
 *      is deliberate. In ERC-4626 a share is a claim on the assets held, so
 *      the share price is `assets / supply` and the vault is solvent by
 *      construction. Here a share's price comes from an index the vault does
 *      not hold, so the two can diverge: if the index rises, the MUSD paid in
 *      by buyers is less than the MUSD owed to redeemers. Calling this a 4626
 *      vault would import a solvency guarantee it does not have.
 *
 *      Three things follow, and they are limits rather than features:
 *
 *      1. **Redemption is paid from reserves and reverts when short.** It does
 *         not pay partially and does not silently round down. `reserves()` and
 *         `liabilities()` are public so the shortfall is visible before anyone
 *         commits, and `InsufficientReserves` names both numbers.
 *      2. **Total exposure is capped** (`maxShares`), so the gap an index rally
 *         can open is bounded by something the deployer chose rather than by
 *         how much was sold.
 *      3. **A backstop may be funded** with `fund()`, by anyone, which is how
 *         a treasury makes redeemers whole. Nothing obliges it to.
 *
 *      On a testnet with parody indices this is an honest demonstration of
 *      issuance, pricing and hardware-confirmed signing. It is not a product
 *      anyone should put money in, and the README says so in those words.
 *
 *      Oracle handling follows the oracle checklist: `decimals()` is read
 *      rather than assumed, the answer must be positive, `startedAt` must be
 *      non-zero, `answeredInRound` must not be behind `roundId`, the answer
 *      must be fresher than `maxStaleness`, and a reverting feed takes the
 *      call down rather than being caught and ignored.
 */
contract IssuanceVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    /// @notice Largest fee the deployer may set, in basis points. 5%.
    uint16 public constant MAX_FEE_BPS = 500;
    uint256 private constant BPS = 10_000;
    uint256 private constant SHARE_ONE = 1e18;

    /// @notice The settlement token. MUSD on Mezo.
    IERC20 public immutable musd;
    /**
     * @notice MUSD's own decimals, read at construction, never assumed.
     * @dev Cached rather than read per call. MUSD is an upgradeable contract,
     *      so in principle its decimals could change under a cached copy;
     *      in practice an ERC-20 that changes decimals breaks every
     *      integrator at once, and reading it on every price call would cost
     *      an external call per trade. The cache is the deliberate choice and
     *      the audit report records it.
     */
    uint8 public immutable musdDecimals;
    /// @notice The index price feed.
    AggregatorV3Interface public immutable oracle;
    /// @notice The feed's decimals, read at construction.
    uint8 public immutable oracleDecimals;
    /// @notice Age past which a price is refused outright.
    uint32 public immutable maxStaleness;
    /// @notice The share token this vault issues.
    ETFShare public share;

    /// @notice Fee on buy and on redeem, in basis points.
    uint16 public feeBps;
    /// @notice Hard cap on shares outstanding.
    uint256 public maxShares;
    /// @notice MUSD collected as fees, excluded from reserves.
    uint256 public feesAccrued;
    /// @notice True while buying and redeeming are halted.
    bool public paused;

    event Bought(address indexed buyer, uint256 musdIn, uint256 fee, uint256 sharesOut, uint256 price);
    event Redeemed(address indexed holder, uint256 sharesIn, uint256 fee, uint256 musdOut, uint256 price);
    event Funded(address indexed from, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event FeeSet(uint16 feeBps);
    event MaxSharesSet(uint256 maxShares);
    event Paused(address indexed guardian);
    event Unpaused(address indexed guardian);

    error ZeroAddress();
    error ZeroAmount();
    error VaultPaused();
    error FeeTooHigh(uint16 feeBps);
    error ShareAlreadySet();
    error CapExceeded(uint256 supplyAfter, uint256 cap);
    error Slippage(uint256 got, uint256 wanted);
    error InsufficientReserves(uint256 owed, uint256 available);
    error StalePrice(uint256 updatedAt, uint32 maxStaleness);
    error BadPrice(int256 answer);
    error IncompleteRound(uint80 roundId, uint80 answeredInRound, uint256 startedAt);

    constructor(
        IERC20 musd_,
        AggregatorV3Interface oracle_,
        uint32 maxStaleness_,
        uint16 feeBps_,
        uint256 maxShares_,
        address admin,
        address guardian,
        address treasurer
    ) {
        if (address(musd_) == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        if (admin == address(0) || guardian == address(0) || treasurer == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        if (maxStaleness_ == 0 || maxShares_ == 0) revert ZeroAmount();

        musd = musd_;
        musdDecimals = IERC20Metadata(address(musd_)).decimals();
        oracle = oracle_;
        oracleDecimals = oracle_.decimals();
        maxStaleness = maxStaleness_;
        feeBps = feeBps_;
        maxShares = maxShares_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(TREASURER_ROLE, treasurer);
    }

    /// @notice Set once, by the factory, immediately after deployment.
    function setShare(ETFShare share_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(share) != address(0)) revert ShareAlreadySet();
        if (address(share_) == address(0)) revert ZeroAddress();
        share = share_;
    }

    /* ------------------------------------------------------------- pricing */

    /**
     * @notice The index price, in MUSD units per whole share.
     * @dev Scaled from the feed's decimals to MUSD's, multiplying before
     *      dividing so a feed with more decimals than the token does not
     *      truncate to zero on the way.
     */
    function price() public view returns (uint256) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        if (answer <= 0) revert BadPrice(answer);
        if (startedAt == 0 || answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound, startedAt);
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice(updatedAt, maxStaleness);

        uint256 raw = uint256(answer);
        if (oracleDecimals == musdDecimals) return raw;
        if (oracleDecimals < musdDecimals) return raw * (10 ** (musdDecimals - oracleDecimals));
        return raw / (10 ** (oracleDecimals - musdDecimals));
    }

    /**
     * @notice MUSD held on behalf of shareholders, excluding accrued fees.
     * @dev Reads `balanceOf` rather than an internal counter, so MUSD sent
     *      here directly counts as reserves. That is a donation, and the only
     *      thing it can do is make redeemers better off: nothing mints
     *      against this number, so it cannot be used to inflate a share price
     *      or dilute a holder. `fund()` exists so that a deliberate top-up is
     *      observable in an event rather than being a bare transfer.
     */
    function reserves() public view returns (uint256) {
        uint256 balance = musd.balanceOf(address(this));
        return balance > feesAccrued ? balance - feesAccrued : 0;
    }

    /// @notice MUSD owed if every share were redeemed at the current price.
    function liabilities() public view returns (uint256) {
        return (share.totalSupply() * price()) / SHARE_ONE;
    }

    /* ---------------------------------------------------------------- buying */

    /**
     * @param musdAmount MUSD to spend, fee inclusive.
     * @param minShares the fewest shares the caller will accept.
     * @dev Checks, then state, then the external pull last but one: the MUSD
     *      transfer and the mint are both after every validation, and the only
     *      untrusted call is to MUSD itself.
     */
    function buy(uint256 musdAmount, uint256 minShares) external nonReentrant returns (uint256 sharesOut) {
        if (paused) revert VaultPaused();
        if (musdAmount == 0) revert ZeroAmount();

        uint256 p = price();
        uint256 fee = (musdAmount * feeBps) / BPS;
        uint256 net = musdAmount - fee;
        sharesOut = (net * SHARE_ONE) / p;
        if (sharesOut == 0) revert ZeroAmount();
        if (sharesOut < minShares) revert Slippage(sharesOut, minShares);

        uint256 supplyAfter = share.totalSupply() + sharesOut;
        if (supplyAfter > maxShares) revert CapExceeded(supplyAfter, maxShares);

        feesAccrued += fee;
        musd.safeTransferFrom(msg.sender, address(this), musdAmount);
        share.mint(msg.sender, sharesOut);

        emit Bought(msg.sender, musdAmount, fee, sharesOut, p);
    }

    /* -------------------------------------------------------------- redeeming */

    /**
     * @param shares shares to burn.
     * @param minMusd the least MUSD the caller will accept.
     * @dev Reverts rather than paying partially when reserves are short; see
     *      the contract notes. The share burn happens before the payout, so a
     *      token that re-enters on transfer finds the supply already reduced.
     */
    function redeem(uint256 shares, uint256 minMusd) external nonReentrant returns (uint256 musdOut) {
        if (paused) revert VaultPaused();
        if (shares == 0) revert ZeroAmount();

        uint256 p = price();
        uint256 gross = (shares * p) / SHARE_ONE;
        // The fee comes from the undivided product rather than from `gross`,
        // so the two divisions do not compound: dividing by SHARE_ONE first
        // and then taking a fee of the result truncates twice, and slither's
        // divide-before-multiply detector is right to say so. The widest
        // operands this contract permits - shares bounded by maxShares and a
        // price in token units - are many orders below uint256's ceiling.
        uint256 fee = (shares * p * feeBps) / (SHARE_ONE * BPS);
        musdOut = gross - fee;
        if (musdOut == 0) revert ZeroAmount();
        if (musdOut < minMusd) revert Slippage(musdOut, minMusd);

        uint256 available = reserves();
        if (gross > available) revert InsufficientReserves(gross, available);

        feesAccrued += fee;
        share.burnFrom(msg.sender, shares);
        musd.safeTransfer(msg.sender, musdOut);

        emit Redeemed(msg.sender, shares, fee, musdOut, p);
    }

    /* ------------------------------------------------------------ management */

    /// @notice Add MUSD to reserves without minting shares. The backstop.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        musd.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /**
     * @notice Withdraw accrued fees.
     * @dev Fees only. Shareholder reserves are not reachable by any role, which
     *      is the one centralisation risk this contract does not carry.
     */
    function withdrawFees(address to, uint256 amount) external nonReentrant onlyRole(TREASURER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > feesAccrued) revert ZeroAmount();
        feesAccrued -= amount;
        musd.safeTransfer(to, amount);
        emit FeesWithdrawn(to, amount);
    }

    function setFeeBps(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps);
        feeBps = newFeeBps;
        emit FeeSet(newFeeBps);
    }

    function setMaxShares(uint256 newMaxShares) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxShares == 0) revert ZeroAmount();
        maxShares = newMaxShares;
        emit MaxSharesSet(newMaxShares);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }
}
