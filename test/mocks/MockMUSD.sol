// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * A stand-in for MUSD in tests, and the basis of the testnet mock where Mezo
 * has not deployed. 18 decimals, like the real one, but the decimals are a
 * constructor argument so a test can prove nothing hardcodes 1e18.
 */
contract MockMUSD is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Mock MUSD", "mMUSD") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
