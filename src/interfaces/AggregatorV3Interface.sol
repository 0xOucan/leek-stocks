// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title AggregatorV3Interface
 * @notice Chainlink's price feed interface, declared here rather than imported.
 *
 * This is an interface, not a service: implementing it needs nothing from
 * Chainlink, and Mezo's own MockAggregator is the same four functions. It is
 * declared locally so this repository has no dependency on a feed provider it
 * does not use, while anything that already consumes Chainlink feeds - Mezo's
 * PriceFeed among them - can consume ours unchanged.
 */
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
