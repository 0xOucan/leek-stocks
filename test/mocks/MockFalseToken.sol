// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * A token whose `transfer` returns false instead of reverting.
 *
 * Legal ERC-20, and the shape that defeats a low-level call whose caller
 * checks only whether the call itself succeeded. MUSD on Mezo is upgradeable,
 * so its future return behaviour is not something this project can assume -
 * which is the whole reason LeekStaking uses a low-level call there, and the
 * reason not checking the return value was self-defeating.
 */
contract MockFalseToken is ERC20 {
    bool public failTransfers;

    constructor() ERC20("False MUSD", "fMUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool value) external {
        failTransfers = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, amount);
    }
}
