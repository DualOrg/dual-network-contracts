// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFeeDispatcher {
    /// @notice Dispatch fees pulled from the Vault for a finalized batch.
    function dispatchFee(bytes32 batchHash, uint256 fee) external returns (bool success);

    /// @notice Distribute ledger fees pushed by the Ledger.
    ///         DUAL must be sent with this call (msg.value == fee).
    function dispatchLedgerFee(bytes32 sourceId, uint256 fee) external payable returns (bool success);
}
