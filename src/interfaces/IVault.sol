// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVault {
    function withdrawForFeeDistribution(
        uint256 amount,
        uint8 sourceType
    ) external returns (bool success);
}
