// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * A token that takes a cut of every transfer.
 *
 * MEZO on Mezo is backed by a precompile over the bank module rather than by
 * ordinary Solidity, so "it is a normal ERC-20" is an assumption and not a
 * fact we read from source. This mock is here so the staking contract is
 * tested against the assumption being wrong: if it ever mints sMEZO from the
 * amount requested instead of the amount received, the supply-equals-stake
 * invariant breaks and the last staker out cannot withdraw.
 */
contract MockFeeToken is ERC20 {
    uint16 public immutable feeBps;

    constructor(uint16 feeBps_) ERC20("Fee On Transfer", "FOT") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Mint and burn pass through whole; only a real transfer is taxed.
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee != 0) super._update(from, address(0), fee);
    }
}
