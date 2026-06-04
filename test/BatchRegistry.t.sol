// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";
import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";
import {IFeeDispatcher} from "../src/interfaces/IFeeDispatcher.sol";

/// @dev A mock SP1 verifier that optionally reverts to simulate invalid proofs.
contract MockSP1Verifier is ISP1Verifier {
    bool public shouldRevert;

    function setRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function verifyProof(bytes32, bytes calldata, bytes calldata) external view override {
        if (shouldRevert) revert("proof invalid");
    }
}

/// @dev A minimal fee dispatcher mock that accepts calls without doing anything.
contract MockFeeDispatcher is IFeeDispatcher {
    uint256 public batchFeesCalled;
    uint256 public ledgerFeesCalled;

    function dispatchFee(bytes32, uint256) external override returns (bool) {
        batchFeesCalled++;
        return true;
    }

    function dispatchLedgerFee(bytes32, uint256) external payable override returns (bool) {
        ledgerFeesCalled++;
        return true;
    }
}

/// @dev A fee dispatcher that always reverts, to test failed-dispatch handling.
contract MockRevertingFeeDispatcher is IFeeDispatcher {
    function dispatchFee(bytes32, uint256) external pure override returns (bool) {
        revert("fee dispatch failed");
    }

    function dispatchLedgerFee(bytes32, uint256) external payable override returns (bool) {
        return true;
    }
}

/// @dev A fee dispatcher that reports a failed pull without reverting.
contract MockFalseFeeDispatcher is IFeeDispatcher {
    function dispatchFee(bytes32, uint256) external pure override returns (bool) {
        return false;
    }

    function dispatchLedgerFee(bytes32, uint256) external payable override returns (bool) {
        return true;
    }
}

contract BatchRegistryTest is Test {
    BatchRegistry registry;
    MockSP1Verifier verifier;
    MockFeeDispatcher feeDispatcher;

    address owner = makeAddr("owner");
    address sequencer = makeAddr("sequencer");
    address challenger = makeAddr("challenger");
    address alice = makeAddr("alice");

    bytes32 constant FRAUD_VKEY = keccak256("fraudVKey");
    bytes32 constant CHECKPOINT_VKEY = keccak256("checkpointVKey");
    uint256 constant CHALLENGE_WINDOW = 1 hours;
    uint256 constant CHALLENGE_BOND = 100_000 ether;

    event BatchAnchored(
        uint256 indexed batchNumber,
        bytes32 indexed batchHash,
        bytes32 indexed integrityRoot,
        bytes32 prevBatchHash,
        bytes32 prevIntegrityRoot,
        bytes32 proofHash,
        string dataUri,
        uint256 fees,
        bool isVerified
    );
    event BatchChallenged(uint256 indexed batchId, address indexed challenger, uint256 bondAmount);
    event ChallengeResolved(uint256 indexed batchId, bool indexed sequencerWasCorrect, uint256 bondAmount);
    event FraudDetected(uint256 indexed batchId, address indexed challenger);
    event BatchFinalized(uint256 indexed batchNumber, bytes32 indexed batchHash);

    function _deployRegistry() internal returns (BatchRegistry) {
        BatchRegistry impl = new BatchRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                BatchRegistry.initialize,
                (owner, sequencer, address(verifier), FRAUD_VKEY, CHECKPOINT_VKEY, CHALLENGE_WINDOW, CHALLENGE_BOND)
            )
        );
        return BatchRegistry(payable(address(proxy)));
    }

    /// @dev Computes the batch hash the same way BatchRegistry does.
    function _batchHash(bytes32 prev, bytes32 commitment) internal pure returns (bytes32) {
        return sha256(abi.encodePacked(prev, commitment));
    }

    function setUp() public {
        verifier = new MockSP1Verifier();
        feeDispatcher = new MockFeeDispatcher();
        registry = _deployRegistry();

        vm.prank(owner);
        registry.setFeeDispatcher(address(feeDispatcher));
    }

    // ── initialize ───────────────────────────────────────────────────────────

    function test_Initialize_SetsParams() public view {
        assertEq(registry.sequencer(), sequencer);
        assertEq(address(registry.zkVerifier()), address(verifier));
        assertEq(registry.fraudProofVKey(), FRAUD_VKEY);
        assertEq(registry.checkpointVKey(), CHECKPOINT_VKEY);
        assertEq(registry.challengeWindow(), CHALLENGE_WINDOW);
        assertEq(registry.owner(), owner);
    }

    function test_Initialize_SetsChallengeBond() public view {
        assertEq(registry.challengeBond(), CHALLENGE_BOND);
    }

    function test_Initialize_HaltOnFraudEnabled() public view {
        assertTrue(registry.haltOnFraud());
    }

    // ── commitBatch ──────────────────────────────────────────────────────────

    function test_CommitBatch_BasicFlow() public {
        bytes32 commitment = keccak256("commit1");
        bytes32 integrityRoot = keccak256("root1");
        bytes32 prevHash = bytes32(0);
        bytes32 expectedHash = _batchHash(prevHash, commitment);

        vm.expectEmit(true, true, true, false);
        emit BatchAnchored(1, expectedHash, integrityRoot, prevHash, bytes32(0), bytes32(0), "ipfs://1", 0, false);
        vm.prank(sequencer);
        registry.commitBatch(prevHash, commitment, integrityRoot, "ipfs://1", 0);

        assertEq(registry.batchCount(), 1);
        assertEq(registry.lastBatchHash(), expectedHash);
    }

    function test_CommitBatch_RevertsFromNonSequencer() public {
        vm.expectRevert(BatchRegistry.Unauthorized.selector);
        vm.prank(alice);
        registry.commitBatch(bytes32(0), keccak256("c"), keccak256("r"), "uri", 0);
    }

    function test_CommitBatch_RevertsOnChainBroken() public {
        vm.expectRevert(BatchRegistry.ChainBroken.selector);
        vm.prank(sequencer);
        registry.commitBatch(keccak256("wrong"), keccak256("c"), keccak256("r"), "uri", 0);
    }

    function test_CommitBatch_RevertsOnEmptyDataUri() public {
        vm.expectRevert(BatchRegistry.EmptyDataURI.selector);
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), keccak256("c"), keccak256("r"), "", 0);
    }

    function test_CommitBatch_RevertsOnZeroCommitment() public {
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), bytes32(0), keccak256("r"), "uri", 0);
    }

    function test_CommitBatch_MultipleBatches_ChainContinuity() public {
        bytes32 c1 = keccak256("c1");
        bytes32 r1 = keccak256("r1");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c1, r1, "uri1", 0);
        bytes32 hash1 = _batchHash(bytes32(0), c1);

        bytes32 c2 = keccak256("c2");
        bytes32 r2 = keccak256("r2");
        vm.prank(sequencer);
        registry.commitBatch(hash1, c2, r2, "uri2", 0);

        assertEq(registry.batchCount(), 2);
        assertEq(registry.lastBatchHash(), _batchHash(hash1, c2));
    }

    // ── commitBatchWithProof ─────────────────────────────────────────────────

    function test_CommitBatchWithProof_FinalizesImmediately() public {
        bytes32 commitment = keccak256("commit");
        bytes32 integrityRoot = keccak256("root");
        bytes32 prevHash = bytes32(0);
        bytes memory publicValues = abi.encode(prevHash, commitment, integrityRoot);

        vm.prank(sequencer);
        registry.commitBatchWithProof(prevHash, commitment, integrityRoot, bytes("proof"), publicValues, "uri", 0);

        bytes32 bHash = _batchHash(prevHash, commitment);
        BatchRegistry.BatchInfo memory info = registry.getBatchInfo(bHash);
        assertTrue(info.isFinalized);
    }

    function test_CommitBatchWithProof_RevertsIfPreviousBatchNotFinalized() public {
        bytes32 c1 = keccak256("c1");
        bytes32 r1 = keccak256("r1");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c1, r1, "uri1", 0);
        bytes32 bHash1 = _batchHash(bytes32(0), c1);

        bytes32 c2 = keccak256("c2");
        bytes32 r2 = keccak256("r2");
        bytes memory publicValues = abi.encode(bHash1, c2, r2);

        vm.expectRevert(BatchRegistry.ChainBroken.selector);
        vm.prank(sequencer);
        registry.commitBatchWithProof(bHash1, c2, r2, bytes("proof"), publicValues, "uri2", 0);

        bytes32 bHash2 = _batchHash(bHash1, c2);
        BatchRegistry.BatchInfo memory info = registry.getBatchInfo(bHash2);
        assertEq(info.timestamp, 0);
        assertEq(registry.batchCount(), 1);
        assertEq(registry.lastBatchHash(), bHash1);
    }

    function test_CommitBatchWithProof_RevertsOnProofMismatch() public {
        bytes32 commitment = keccak256("commit");
        bytes32 integrityRoot = keccak256("root");
        bytes32 prevHash = bytes32(0);
        // Public values bind to a different commitment — proof must match this batch exactly.
        bytes memory publicValues = abi.encode(prevHash, keccak256("wrong"), integrityRoot);

        vm.expectRevert(BatchRegistry.InvalidProof.selector);
        vm.prank(sequencer);
        registry.commitBatchWithProof(prevHash, commitment, integrityRoot, bytes("proof"), publicValues, "uri", 0);
    }

    function test_CommitBatchWithProof_RevertsOnInvalidProof() public {
        verifier.setRevert(true);

        bytes32 commitment = keccak256("commit");
        bytes32 integrityRoot = keccak256("root");
        bytes32 prevHash = bytes32(0);
        bytes memory publicValues = abi.encode(prevHash, commitment);

        vm.expectRevert();
        vm.prank(sequencer);
        registry.commitBatchWithProof(prevHash, commitment, integrityRoot, bytes("bad_proof"), publicValues, "uri", 0);
    }

    // ── challengeBatch ────────────────────────────────────────────────────────

    function test_ChallengeBatch_RequiresBond() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.deal(challenger, CHALLENGE_BOND);
        vm.expectEmit(true, true, false, true);
        emit BatchChallenged(1, challenger, CHALLENGE_BOND);
        vm.prank(challenger);
        registry.challengeBatch{value: CHALLENGE_BOND}(bHash);

        BatchRegistry.BatchInfo memory info = registry.getBatchInfo(bHash);
        assertTrue(info.isChallenged);
        assertEq(info.challenger, challenger);
    }

    function test_ChallengeBatch_RevertsOnBondTooLow() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.deal(challenger, CHALLENGE_BOND);
        vm.expectRevert(BatchRegistry.BondTooLow.selector);
        vm.prank(challenger);
        registry.challengeBatch{value: CHALLENGE_BOND - 1}(bHash);
    }

    function test_ChallengeBatch_RevertsAfterChallengeWindow() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        // At exactly batch.timestamp + challengeWindow the window is closed (M-2 fix).
        vm.warp(block.timestamp + CHALLENGE_WINDOW);

        vm.deal(challenger, CHALLENGE_BOND);
        vm.expectRevert(BatchRegistry.ChallengePeriodActive.selector);
        vm.prank(challenger);
        registry.challengeBatch{value: CHALLENGE_BOND}(bHash);
    }

    function test_ChallengeBatch_RevertsOnAlreadyChallenged() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.deal(challenger, CHALLENGE_BOND);
        vm.prank(challenger);
        registry.challengeBatch{value: CHALLENGE_BOND}(bHash);

        vm.deal(alice, CHALLENGE_BOND);
        vm.expectRevert(BatchRegistry.AlreadyChallenged.selector);
        vm.prank(alice);
        registry.challengeBatch{value: CHALLENGE_BOND}(bHash);
    }

    function test_ChallengeBatch_RevertsOnNonExistentBatch() public {
        vm.deal(challenger, 1 ether);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        vm.prank(challenger);
        registry.challengeBatch{value: 0.1 ether}(keccak256("nonexistent"));
    }

    // ── resolveChallenge ─────────────────────────────────────────────────────

    function test_ResolveChallenge_SequencerCorrect_ReturnsBondToSequencer() public {
        bytes32 commitment = keccak256("c");
        bytes32 integrityRoot = keccak256("r");
        bytes32 prevHash = bytes32(0);
        vm.prank(sequencer);
        registry.commitBatch(prevHash, commitment, integrityRoot, "uri", 0);
        bytes32 bHash = _batchHash(prevHash, commitment);

        vm.deal(challenger, CHALLENGE_BOND);
        vm.prank(challenger);
        registry.challengeBatch{value: CHALLENGE_BOND}(bHash);

        // Proof confirms sequencer was correct: integrity root matches what was committed.
        bytes memory publicValues = abi.encode(prevHash, commitment, integrityRoot);

        vm.expectEmit(true, true, false, true);
        emit ChallengeResolved(1, true, CHALLENGE_BOND);
        registry.resolveChallenge(bHash, bytes("proof"), publicValues);

        // Pull-pattern (H-4): bond credited to sequencer's pending withdrawals.
        assertEq(registry.pendingWithdrawals(sequencer), CHALLENGE_BOND);

        BatchRegistry.BatchInfo memory info = registry.getBatchInfo(bHash);
        assertTrue(info.isFinalized);
    }

    function test_ResolveChallenge_FraudDetected_ReturnsBondToChallenger() public {
        bytes32 prevHash = bytes32(0);
        bytes32 commitment = keccak256("c");
        bytes32 integrityRoot = keccak256("r");
        vm.prank(sequencer);
        registry.commitBatch(prevHash, commitment, integrityRoot, "uri", 0);
        bytes32 bHash = _batchHash(prevHash, commitment);

        vm.deal(challenger, CHALLENGE_BOND);
        vm.prank(challenger);
        registry.challengeBatch{value: CHALLENGE_BOND}(bHash);

        // Proof reveals fraud: same batch hash but a different (true) integrity root.
        bytes32 fraudRoot = keccak256("fraudRoot");
        bytes memory publicValues = abi.encode(prevHash, commitment, fraudRoot);

        vm.expectEmit(true, true, false, false);
        emit FraudDetected(1, challenger);
        registry.resolveChallenge(bHash, bytes("proof"), publicValues);

        // Pull-pattern (H-4): bond credited to challenger's pending withdrawals.
        assertEq(registry.pendingWithdrawals(challenger), CHALLENGE_BOND);
        assertTrue(registry.paused()); // haltOnFraud is true by default
    }

    function test_ResolveChallenge_RevertsOnNotChallenged() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        bytes memory publicValues = abi.encode(bytes32(0), c);
        vm.expectRevert(BatchRegistry.BatchNotChallenged.selector);
        registry.resolveChallenge(bHash, bytes("proof"), publicValues);
    }

    // ── finalizeBatch ─────────────────────────────────────────────────────────

    function test_FinalizeBatch_AfterChallengeWindow() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);

        vm.expectEmit(true, true, false, false);
        emit BatchFinalized(1, bHash);
        registry.finalizeBatch(bHash);

        BatchRegistry.BatchInfo memory info = registry.getBatchInfo(bHash);
        assertTrue(info.isFinalized);
    }

    function test_FinalizeBatch_RevertsBeforeChallengeWindow() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.expectRevert(BatchRegistry.ChallengePeriodActive.selector);
        registry.finalizeBatch(bHash);
    }

    function test_FinalizeBatch_RevertsOnAlreadyFinalized() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        registry.finalizeBatch(bHash);

        vm.expectRevert(BatchRegistry.AlreadyFinalized.selector);
        registry.finalizeBatch(bHash);
    }

    function test_FinalizeBatch_RevertsIfChallenged() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.deal(challenger, CHALLENGE_BOND);
        vm.prank(challenger);
        registry.challengeBatch{value: CHALLENGE_BOND}(bHash);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        vm.expectRevert(BatchRegistry.AlreadyChallenged.selector);
        registry.finalizeBatch(bHash);
    }

    function test_FinalizeBatch_RevertsIfPreviousBatchNotFinalized() public {
        bytes32 c1 = keccak256("c1");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c1, keccak256("r1"), "uri1", 0);
        bytes32 bHash1 = _batchHash(bytes32(0), c1);

        bytes32 c2 = keccak256("c2");
        vm.prank(sequencer);
        registry.commitBatch(bHash1, c2, keccak256("r2"), "uri2", 0);
        bytes32 bHash2 = _batchHash(bHash1, c2);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);

        vm.expectRevert(BatchRegistry.ChainBroken.selector);
        registry.finalizeBatch(bHash2);

        registry.finalizeBatch(bHash1);
        registry.finalizeBatch(bHash2);

        assertEq(registry.highestFinalizedBatchNumber(), 2);
    }

    // ── admin functions ───────────────────────────────────────────────────────

    function test_SetFeeDispatcher_UpdatesDispatcher() public {
        address newDispatcher = makeAddr("newDispatcher");
        vm.prank(owner);
        registry.setFeeDispatcher(newDispatcher);

        assertEq(address(registry.feeDispatcher()), newDispatcher);
    }

    function test_SetFeeDispatcher_RevertsFromNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        registry.setFeeDispatcher(makeAddr("x"));
    }

    function test_SetChallengeConfig_UpdatesValues() public {
        uint256 newBond = 200_000 ether;
        vm.prank(owner);
        registry.setChallengeConfig(2 hours, newBond);

        assertEq(registry.challengeWindow(), 2 hours);
        assertEq(registry.challengeBond(), newBond);
    }

    function test_SetChallengeConfig_RevertsOnZeroWindow() public {
        vm.prank(owner);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        registry.setChallengeConfig(0, 0.1 ether);
    }

    function test_SetSequencer_UpdatesSequencer() public {
        address newSeq = makeAddr("newSeq");
        vm.prank(owner);
        registry.setSequencer(newSeq);

        assertEq(registry.sequencer(), newSeq);
    }

    function test_SetSequencer_RevertsFromNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        registry.setSequencer(makeAddr("newSeq"));
    }

    function test_SetHaltOnFraud_UpdatesFlag() public {
        vm.prank(owner);
        registry.setHaltOnFraud(false);

        assertFalse(registry.haltOnFraud());
    }

    // ── pause / unpause ───────────────────────────────────────────────────────

    function test_Pause_BlocksCommit() public {
        vm.prank(owner);
        registry.pause();

        vm.expectRevert();
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), keccak256("c"), keccak256("r"), "uri", 0);
    }

    function test_Unpause_AllowsCommit() public {
        vm.prank(owner);
        registry.pause();
        vm.prank(owner);
        registry.unpause();

        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), keccak256("c"), keccak256("r"), "uri", 0);
        assertEq(registry.batchCount(), 1);
    }

    // ── setChallengeConfig bond below minimum ─────────────────────────────────

    function test_SetChallengeConfig_RevertsOnBondBelowMinimum() public {
        vm.prank(owner);
        vm.expectRevert(BatchRegistry.BondBelowMinimum.selector);
        registry.setChallengeConfig(1 hours, 0.1 ether);
    }

    // ── pull-pattern withdrawals ──────────────────────────────────────────────

    function test_ClaimWithdrawal_SequencerReceivesBond() public {
        bytes32 commitment = keccak256("c");
        bytes32 integrityRoot = keccak256("r");
        bytes32 prevHash = bytes32(0);
        vm.prank(sequencer);
        registry.commitBatch(prevHash, commitment, integrityRoot, "uri", 0);
        bytes32 bHash = _batchHash(prevHash, commitment);

        vm.deal(challenger, CHALLENGE_BOND);
        vm.prank(challenger);
        registry.challengeBatch{value: CHALLENGE_BOND}(bHash);

        bytes memory publicValues = abi.encode(prevHash, commitment, integrityRoot);
        registry.resolveChallenge(bHash, bytes("proof"), publicValues);

        assertEq(registry.pendingWithdrawals(sequencer), CHALLENGE_BOND);

        uint256 before = sequencer.balance;
        vm.prank(sequencer);
        registry.claimWithdrawal();

        assertEq(sequencer.balance - before, CHALLENGE_BOND);
        assertEq(registry.pendingWithdrawals(sequencer), 0);
    }

    function test_ClaimWithdrawal_RevertsOnNothingToClaim() public {
        vm.expectRevert(BatchRegistry.NothingToClaim.selector);
        vm.prank(alice);
        registry.claimWithdrawal();
    }

    // ── retryDispatchFee ──────────────────────────────────────────────────────

    function test_RetryDispatchFee_SucceedsAfterFailure() public {
        MockRevertingFeeDispatcher badDispatcher = new MockRevertingFeeDispatcher();
        vm.prank(owner);
        registry.setFeeDispatcher(address(badDispatcher));

        bytes32 c = keccak256("c");
        uint256 fee = 100;
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", fee);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        registry.finalizeBatch(bHash);

        assertEq(registry.pendingFeeDispatch(bHash), fee);

        // Swap in a working dispatcher and retry.
        vm.prank(owner);
        registry.setFeeDispatcher(address(feeDispatcher));
        registry.retryDispatchFee(bHash);

        assertEq(registry.pendingFeeDispatch(bHash), 0);
    }

    function test_FinalizeBatch_PendsDispatchWhenDispatcherReturnsFalse() public {
        MockFalseFeeDispatcher falseDispatcher = new MockFalseFeeDispatcher();
        vm.prank(owner);
        registry.setFeeDispatcher(address(falseDispatcher));

        bytes32 c = keccak256("c");
        uint256 fee = 100;
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", fee);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        registry.finalizeBatch(bHash);

        BatchRegistry.BatchInfo memory info = registry.getBatchInfo(bHash);
        assertFalse(info.feeDispatched);
        assertEq(registry.pendingFeeDispatch(bHash), fee);
    }

    function test_RetryDispatchFee_SucceedsAfterMissingDispatcher() public {
        vm.prank(owner);
        registry.setFeeDispatcher(address(0));

        bytes32 c = keccak256("c");
        uint256 fee = 100;
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", fee);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        registry.finalizeBatch(bHash);

        BatchRegistry.BatchInfo memory info = registry.getBatchInfo(bHash);
        assertFalse(info.feeDispatched);
        assertEq(registry.pendingFeeDispatch(bHash), fee);

        vm.prank(owner);
        registry.setFeeDispatcher(address(feeDispatcher));
        registry.retryDispatchFee(bHash);

        info = registry.getBatchInfo(bHash);
        assertTrue(info.feeDispatched);
        assertEq(registry.pendingFeeDispatch(bHash), 0);
    }

    function test_RetryDispatchFee_RevertsIfNoPending() public {
        vm.expectRevert(BatchRegistry.NoPendingDispatch.selector);
        registry.retryDispatchFee(keccak256("nonexistent"));
    }

    // ── emergencyWithdraw / withdrawableSurplus ───────────────────────────────

    function test_EmergencyWithdraw_TransfersSurplus() public {
        vm.deal(address(registry), 1 ether);
        assertEq(registry.withdrawableSurplus(), 1 ether);

        address payable recipient = payable(makeAddr("recipient"));
        uint256 before = recipient.balance;

        vm.prank(owner);
        registry.emergencyWithdraw(recipient, 0.5 ether);

        assertEq(recipient.balance - before, 0.5 ether);
        assertEq(registry.withdrawableSurplus(), 0.5 ether);
    }

    function test_EmergencyWithdraw_RevertsOnExceedsSurplus() public {
        vm.deal(address(registry), 1 ether);

        vm.expectRevert(BatchRegistry.AmountExceedsSurplus.selector);
        vm.prank(owner);
        registry.emergencyWithdraw(payable(makeAddr("r")), 2 ether);
    }

    function test_WithdrawableSurplus_ExcludesActiveBonds() public {
        bytes32 c = keccak256("c");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, keccak256("r"), "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.deal(challenger, CHALLENGE_BOND);
        vm.prank(challenger);
        registry.challengeBatch{value: CHALLENGE_BOND}(bHash);

        // The bond is an active obligation — surplus must be 0.
        assertEq(registry.withdrawableSurplus(), 0);
    }

    // ── setBatchState / setCheckpointState ────────────────────────────────────

    function test_SetBatchState_RevertsWhenNotPaused() public {
        vm.expectRevert();
        vm.prank(owner);
        registry.setBatchState(bytes32(0), bytes32(0), 0);
    }

    function test_SetBatchState_ResetsState() public {
        bytes32 c = keccak256("c");
        bytes32 r = keccak256("r");
        vm.prank(sequencer);
        registry.commitBatch(bytes32(0), c, r, "uri", 0);
        bytes32 bHash = _batchHash(bytes32(0), c);

        vm.prank(owner);
        registry.pause();

        vm.prank(owner);
        registry.setBatchState(bHash, r, 1);

        assertEq(registry.lastBatchHash(), bHash);
        assertEq(registry.lastIntegrityRoot(), r);
        assertEq(registry.highestFinalizedBatchNumber(), 1);
    }

    function test_SetCheckpointState_RevertsWhenNotPaused() public {
        vm.expectRevert();
        vm.prank(owner);
        registry.setCheckpointState(bytes32(0), 0);
    }
}
