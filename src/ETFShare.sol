// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title ETFShare
 * @notice A share token for one parody index. 18 decimals.
 *
 * @dev **This is not a security and is not backed by anything.** The index is
 *      a parody - Gologgle, Amezon - published by this project's own oracle.
 *      The name is deliberately not that of any real company, the token makes
 *      no claim on any real asset, and `DISCLAIMER` travels with the contract
 *      so that the claim cannot be separated from the token by a front end.
 *
 *      **Minting is bounded and the minter set is frozen at construction.**
 *      Both are the fix for a demonstrated drain (test/AdminTheft.t.sol):
 *
 *      OpenZeppelin's `AccessControl` defaults every role's admin to
 *      `DEFAULT_ADMIN_ROLE` unless `_setRoleAdmin` says otherwise. Nothing
 *      here used to say otherwise, so this contract's admin - the same
 *      address `ETFFactory` gives the vaults - could grant itself
 *      `MINTER_ROLE`, print shares against no MUSD at all, and redeem them
 *      against the reserves other holders had paid in. 99.5% of a 99,750
 *      MUSD pot, in three calls, without ever touching the vault's own admin
 *      key. `maxShares` did not help: the vault checks it in `buy` and never
 *      in `mint`, so the printed supply exceeded the deployer's chosen cap by
 *      a factor of ten in the second test.
 *
 *      Two independent changes, because either alone leaves a hole:
 *
 *      1. `MINTER_ROLE` and `BURNER_ROLE` administer themselves, so the
 *         admin cannot grant them and the holder set is whatever the
 *         constructor set. The vault holds both and contains no `grantRole`
 *         call, so in practice the set is frozen for good.
 *      2. `maxSupply` is enforced in `mint` itself. A cap that lives in the
 *         caller is a cap that applies to one caller; this one applies to
 *         every minter that ever exists, including a future bridge.
 *
 *      The cost is that bridging these shares later - the Wormhole NTT case
 *      the separate roles were for - needs a redeploy rather than a role
 *      grant. That is the right trade: an admin who can add a minter is an
 *      admin who can print, and this token's whole claim is that it cannot be
 *      printed.
 *
 *      ERC20Permit is included because the vault pulls shares on redeem, and a
 *      permit saves the user an approve transaction. Nonces and the domain
 *      separator come from OpenZeppelin rather than being hand-rolled.
 */
contract ETFShare is ERC20, ERC20Permit, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /**
     * @notice The most shares that can ever exist.
     * @dev Mirrors the vault's `maxShares` and is enforced here as well, so
     *      the bound does not depend on which contract is doing the minting.
     */
    uint256 public immutable maxSupply;

    string public constant DISCLAIMER =
        "Parody index token. Not a security. Not backed by any real asset or company. Testnet only.";

    error ZeroAddress();
    error ZeroAmount();
    error CapExceeded(uint256 supplyAfter, uint256 cap);

    constructor(string memory name_, string memory symbol_, address admin, address vault, uint256 maxSupply_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (admin == address(0) || vault == address(0)) revert ZeroAddress();
        if (maxSupply_ == 0) revert ZeroAmount();
        maxSupply = maxSupply_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, vault);
        _grantRole(BURNER_ROLE, vault);

        /* Each of these roles becomes its own administrator, which takes the
           power to grant it away from DEFAULT_ADMIN_ROLE. Set after the
           grants above, because _setRoleAdmin first would leave this
           constructor unable to grant them to the vault. */
        _setRoleAdmin(MINTER_ROLE, MINTER_ROLE);
        _setRoleAdmin(BURNER_ROLE, BURNER_ROLE);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // Checked here and not only in the vault: see the contract notes.
        uint256 supplyAfter = totalSupply() + amount;
        if (supplyAfter > maxSupply) revert CapExceeded(supplyAfter, maxSupply);
        _mint(to, amount);
    }

    /**
     * @dev Burns from `from`, which must have allowed the caller. The vault
     *      therefore cannot burn a holder's shares without an approval, and
     *      `_spendAllowance` is what enforces it.
     */
    function burnFrom(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (from != msg.sender) _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}
