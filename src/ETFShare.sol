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
 *      Mint and burn are role-gated rather than owner-gated, and the roles are
 *      separate, because the issuance vault needs both while a Wormhole NTT
 *      manager - if these shares are ever bridged - needs the same two without
 *      inheriting anything else.
 *
 *      ERC20Permit is included because the vault pulls shares on redeem, and a
 *      permit saves the user an approve transaction. Nonces and the domain
 *      separator come from OpenZeppelin rather than being hand-rolled.
 */
contract ETFShare is ERC20, ERC20Permit, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    string public constant DISCLAIMER =
        "Parody index token. Not a security. Not backed by any real asset or company. Testnet only.";

    error ZeroAddress();
    error ZeroAmount();

    constructor(string memory name_, string memory symbol_, address admin, address vault)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (admin == address(0) || vault == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, vault);
        _grantRole(BURNER_ROLE, vault);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
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
