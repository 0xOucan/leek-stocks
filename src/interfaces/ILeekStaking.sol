// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * The part of LeekStaking the vault depends on.
 *
 * An interface rather than an import so the dependency runs one way: the
 * staking contract knows nothing about any vault, and a vault can be deployed
 * before any staking contract exists.
 */
interface ILeekStaking {
    /// @notice Share of a fee this account does not pay, in basis points.
    function discountBpsFor(address account) external view returns (uint16);

    /// @notice Total sMEZO, i.e. whether anyone is staked at all.
    function totalSupply() external view returns (uint256);

    /// @notice Account for MUSD sent here and credit it to stakers.
    function notifyReward() external returns (uint256);
}
