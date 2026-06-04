// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILedger {
    struct SingleFeeParams {
        bytes32 refId;
        uint256 tokenId;
        uint256 fee;
        uint256 timestamp;
    }

    struct SnapshotFeeParams {
        bytes32 refId;
        bytes32 from;
        bytes32 to;
        uint256 entriesCount;
        uint256 fee;
        bytes32 digest;
    }

    function processSingleFee(SingleFeeParams calldata params) external;

    function processSnapshotFee(SnapshotFeeParams calldata params) external;
}
