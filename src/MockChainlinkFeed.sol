// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IChainLinkOracle} from "./interfaces/IChainLinkOracle.sol";

/**
 * @title Mock Chainlink Feed
 * @notice Mutable 8-decimal Chainlink-style feed for local simulations and tests.
 */
contract MockChainlinkFeed is IChainLinkOracle {
    int256 public answer;
    uint80 public roundId;
    uint256 public updatedAt;

    event AnswerUpdated(int256 answer, uint80 roundId, uint256 updatedAt);

    constructor(int256 _answer) {
        _setAnswer(_answer);
    }

    function setAnswer(int256 _answer) external {
        _setAnswer(_answer);
    }

    function refresh() external {
        updatedAt = block.timestamp;
        roundId += 1;
        emit AnswerUpdated(answer, roundId, updatedAt);
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    function _setAnswer(int256 _answer) internal {
        require(_answer > 0, "Invalid answer");
        answer = _answer;
        updatedAt = block.timestamp;
        roundId += 1;
        emit AnswerUpdated(_answer, roundId, updatedAt);
    }
}
