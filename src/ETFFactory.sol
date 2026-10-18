// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ETFShare} from "./ETFShare.sol";
import {IssuanceVault} from "./IssuanceVault.sol";

/**
 * @title ETFFactory
 * @notice Deploys one index's share token and issuance vault.
 *
 * @dev **`deployETF(string,string)` takes two strings and nothing else, and
 *      that signature is a hard requirement rather than a style choice.**
 *
 *      LeekWallet draws a transaction on a 128x64 screen and refuses what it
 *      cannot draw. Its predecessor on Hedera failed this test: an issuance
 *      call carrying a seventeen-field struct came to 3,748 bytes against a
 *      768-byte limit, and a screen reading "deploy equity, approve?" over
 *      3.7 KB nobody can read is blind signing with better manners. The fix
 *      there, and the design here, is to freeze everything that does not vary
 *      in registry state, so the only values in the calldata are the two a
 *      human actually decides: the name and the symbol.
 *
 *      Everything else - the settlement token, the price feed, the fee, the
 *      cap, the roles - is set by an admin in `registerIndex` before anyone
 *      deploys, and is visible on chain. Adding a parameter to `deployETF`
 *      would break the wallet's ability to show the call honestly, which is
 *      the whole point of the project it belongs to.
 */
contract ETFFactory is AccessControl {
    struct IndexConfig {
        AggregatorV3Interface oracle;
        uint32 maxStaleness;
        uint16 feeBps;
        /// @dev Share of each fee that stays in reserves; the funded backstop.
        uint16 reserveShareBps;
        uint256 maxShares;
        /// @dev Pause authority on the deployed vault. Should be a multisig.
        address guardian;
        /// @dev May withdraw accrued fees, and nothing else.
        address treasurer;
        bool registered;
    }

    /// @notice The settlement token for every index this factory deploys.
    IERC20 public immutable musd;
    /// @notice Administrator of every pair this factory deploys. Set once.
    address public immutable admin;

    /// @dev symbol hash => frozen configuration.
    mapping(bytes32 symbolHash => IndexConfig) private _configs;
    /// @dev symbol hash => the vault deployed for it, or zero.
    mapping(bytes32 symbolHash => address vault) public vaultFor;
    /// @notice Every vault this factory has deployed, in order.
    address[] public vaults;

    event IndexRegistered(
        string symbol,
        address indexed oracle,
        uint32 maxStaleness,
        uint16 feeBps,
        uint16 reserveShareBps,
        uint256 maxShares,
        address guardian,
        address treasurer
    );
    event IndexDeployed(string name, string symbol, address indexed share, address indexed vault);

    error ZeroAddress();
    error EmptyString();
    error NotRegistered(string symbol);
    error AlreadyDeployed(string symbol);
    error AlreadyRegistered(string symbol);
    error SameHolder(address holder);

    constructor(IERC20 musd_, address admin_) {
        if (address(musd_) == address(0) || admin_ == address(0)) revert ZeroAddress();
        musd = musd_;
        admin = admin_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /**
     * @notice Freeze the configuration a symbol will be deployed with.
     * @dev Write-once per symbol. A re-registration would change what a
     *      pending `deployETF` means between the user reading it on a device
     *      screen and the transaction landing, which is exactly the class of
     *      surprise this design exists to remove.
     */
    function registerIndex(
        string calldata symbol,
        AggregatorV3Interface oracle,
        uint32 maxStaleness,
        uint16 feeBps,
        uint16 reserveShareBps,
        uint256 maxShares,
        address guardian,
        address treasurer
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(symbol).length == 0) revert EmptyString();
        if (address(oracle) == address(0)) revert ZeroAddress();
        // Separate keys, named here rather than defaulted to the admin: one
        // key that can pause a market and also move its fees is the
        // centralisation the security checklist tells us to flag, and the
        // registry is the right place to name three distinct holders because
        // it keeps deployETF's calldata at two strings.
        if (guardian == address(0) || treasurer == address(0)) revert ZeroAddress();
        /*
         * And genuinely separate.
         *
         * The comment above has said "separate keys" since the first version
         * while nothing enforced it, and both default to the admin in the
         * deploy scripts. One address holding both can detach the staking
         * contract - stopping every staker's rewards while trading continues
         * normally - and then withdraw the fees that accumulate instead.
         * `emergencyUnsetStaking` was handed to the guardian on the explicit
         * argument that it "cannot take value: the treasury share simply
         * accrues to feesAccrued, where only TREASURER_ROLE can reach it".
         * That argument is only true if this holds.
         */
        if (guardian == treasurer) revert SameHolder(guardian);
        bytes32 key = keccak256(bytes(symbol));
        if (_configs[key].registered) revert AlreadyRegistered(symbol);

        _configs[key] = IndexConfig({
            oracle: oracle,
            maxStaleness: maxStaleness,
            feeBps: feeBps,
            reserveShareBps: reserveShareBps,
            maxShares: maxShares,
            guardian: guardian,
            treasurer: treasurer,
            registered: true
        });
        emit IndexRegistered(
            symbol, address(oracle), maxStaleness, feeBps, reserveShareBps, maxShares, guardian, treasurer
        );
    }

    /**
     * @notice Deploy the share token and vault for a registered symbol.
     *
     * @dev Admin-gated. This used to be permissionless, on the argument that
     *      "the configuration is already frozen, so there is nothing for a
     *      caller to choose". The configuration is frozen; `name` is not.
     *
     *      Only `symbol` is the registry key, so once an index is registered
     *      anyone could front-run the admin's own call with their own `name`
     *      string. `vaultFor[key]` is then written, the admin's call reverts
     *      with `AlreadyDeployed`, `registerIndex` cannot be redone, and
     *      there is no reset anywhere in this contract - so the share token's
     *      `name()` is the stranger's text forever, on an otherwise correctly
     *      configured vault whose roles went to the honest admin. Every front
     *      end and explorer keyed on the symbol would display it, and
     *      recovery needs a new factory and a new symbol.
     *
     *      Not a theft path, since the roles and the config are right either
     *      way. A permanent, unrecoverable hijack of the user-visible
     *      identity, available to anybody, which a modifier closes.
     */
    function deployETF(string calldata name, string calldata symbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (address shareAddress, address vaultAddress)
    {
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyString();
        bytes32 key = keccak256(bytes(symbol));
        IndexConfig memory config = _configs[key];
        if (!config.registered) revert NotRegistered(symbol);
        if (vaultFor[key] != address(0)) revert AlreadyDeployed(symbol);

        IssuanceVault vault = new IssuanceVault(
            musd,
            config.oracle,
            config.maxStaleness,
            config.feeBps,
            config.reserveShareBps,
            config.maxShares,
            address(this), // admin for one call: setShare, then handed over
            config.guardian,
            config.treasurer
        );
        // The cap goes to the share token as well as to the vault, so the
        // supply bound holds whoever is minting. See ETFShare's notes.
        ETFShare shareToken = new ETFShare(name, symbol, admin, address(vault), config.maxShares);

        // Registry written before the calls into the new vault. Those calls
        // are to a contract deployed two lines above, so re-entry is not
        // reachable today, but ordering state first costs nothing and keeps
        // the function Checks-Effects-Interactions whatever it grows into.
        vaultFor[key] = address(vault);
        vaults.push(address(vault));

        vault.setShare(shareToken);
        // Hand administration to the configured admin and step out of the way,
        // so the factory keeps no standing power over what it deployed.
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), admin);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), address(this));

        emit IndexDeployed(name, symbol, address(shareToken), address(vault));
        return (address(shareToken), address(vault));
    }

    function configFor(string calldata symbol) external view returns (IndexConfig memory) {
        return _configs[keccak256(bytes(symbol))];
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

}
