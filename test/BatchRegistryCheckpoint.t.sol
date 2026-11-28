// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";
import {BatchRegistryV1} from "./legacy/BatchRegistryV1.sol";
import {IFeeDispatcher} from "../src/interfaces/IFeeDispatcher.sol";
import {UpgradeBatchRegistry} from "../script/UpgradeBatchRegistry.s.sol";

/// @dev Accepts every proof for the checkpoint and fraud keys unless told to fail.
contract CkptVerifier is ISP1Verifier {
    bool public shouldRevert;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function verifyProof(bytes32 vkey, bytes calldata, bytes calldata) external view override {
        if (shouldRevert) revert("bad proof");
        if (vkey != keccak256("ckpt") && vkey != keccak256("fraud")) revert("wrong vkey");
    }
}

/// @dev Records the order of dispatched batch fees.
contract CkptDispatcher is IFeeDispatcher {
    bytes32[] public dispatched;

    function dispatchFee(bytes32 batchHash, uint256) external override returns (bool) {
        dispatched.push(batchHash);
        return true;
    }

    function dispatchLedgerFee(bytes32, uint256) external payable override returns (bool) {
        return true;
    }

    function count() external view returns (uint256) {
        return dispatched.length;
    }
}

/// @dev finalizeCheckpoint, the bond floor and the checkpoint upgrade (reinitializeCheckpoints).
contract BatchRegistryCheckpointTest is Test {
    BatchRegistry internal reg;
    CkptVerifier internal verifier;
    CkptDispatcher internal dispatcher;

    address internal owner = makeAddr("owner");
    address internal sequencer = makeAddr("sequencer");
    address internal challenger = makeAddr("challenger");

    uint256 internal constant WINDOW = 1 hours;
    uint256 internal constant BOND = 100_000 ether;
    uint256 internal constant MIN_BOND = 10 ether;
    uint256 internal constant MAX_BATCHES = 5;
    uint256 internal constant FEE = 1 ether;
    bytes32 internal constant FRAUD = keccak256("fraud");
    bytes32 internal constant CKPT = keccak256("ckpt");

    event BatchFinalized(uint256 indexed batchNumber, bytes32 indexed batchHash);
    event ChallengeResolved(uint256 indexed batchNumber, bool indexed sequencerWasCorrect, uint256 bondAmount);
    event CheckpointFinalized(
        bytes32 indexed startBatchHash,
        bytes32 indexed endBatchHash,
        uint256 batchNumber,
        bytes32 proofHash,
        string dataUri
    );
    event FinalizingCheckpointsStarted(bytes32 indexed startBatchHash, uint256 startBatchNumber);
    event MinChallengeBondUpdated(uint256 oldMinimum, uint256 newMinimum);
    event MaxCheckpointBatchesUpdated(uint256 oldMaximum, uint256 newMaximum);

    bytes32[] internal hashes; // hashes[n] = hash of batch n; hashes[0] = bytes32(0)

    function setUp() public {
        vm.warp(1_000_000);
        verifier = new CkptVerifier();
        dispatcher = new CkptDispatcher();
        reg = BatchRegistry(payable(address(new ERC1967Proxy(address(new BatchRegistry()), _initData()))));
        vm.startPrank(owner);
        reg.reinitializeCheckpoints(new bytes32[](0), MIN_BOND, MAX_BATCHES);
        reg.setFeeDispatcher(address(dispatcher));
        vm.stopPrank();
        hashes.push(bytes32(0));
    }

    function _initData() internal view returns (bytes memory) {
        return
            abi.encodeCall(BatchRegistry.initialize, (owner, sequencer, address(verifier), FRAUD, CKPT, WINDOW, BOND));
    }

    function _root(uint256 n) internal pure returns (bytes32) {
        return n == 0 ? bytes32(0) : keccak256(abi.encode("root", n));
    }

    /// @dev Commits `k` batches with a fee on `registry` (current or V1 ABI: same selector).
    function _commit(address registry, uint256 k) internal {
        for (uint256 i = 0; i < k; i++) {
            uint256 n = hashes.length;
            bytes32 prev = hashes[n - 1];
            bytes32 c = keccak256(abi.encode("c", n));
            vm.prank(sequencer);
            BatchRegistry(payable(registry)).commitBatch(prev, c, _root(n), "uri", FEE);
            hashes.push(sha256(abi.encodePacked(prev, c)));
        }
    }

    /// @dev `sha256(root_{start+1} || ... || root_end)` over the honest roots.
    function _digest(uint256 start, uint256 end) internal pure returns (bytes32) {
        bytes memory roots;
        for (uint256 n = start + 1; n <= end; n++) {
            roots = bytes.concat(roots, _root(n));
        }
        return sha256(roots);
    }

    function _pv(uint256 start, uint256 end) internal view returns (bytes memory) {
        return abi.encode(hashes[start], _root(start), hashes[end], _digest(start, end));
    }

    // ── finalizeCheckpoint: effect ────────────────────────────────────────────

    function test_FinalizeCheckpoint_FinalizesRangeInOrderAndDispatchesFees() public {
        _commit(address(reg), 3);

        for (uint256 n = 1; n <= 3; n++) {
            vm.expectEmit(true, true, false, false, address(reg));
            emit BatchFinalized(n, hashes[n]);
        }
        bytes memory pv = _pv(0, 3);
        vm.expectCall(address(verifier), abi.encodeCall(ISP1Verifier.verifyProof, (CKPT, pv, "p")));
        vm.expectEmit(true, true, false, true, address(reg));
        emit CheckpointFinalized(hashes[0], hashes[3], 3, keccak256("p"), "ckpt-uri");
        reg.finalizeCheckpoint("p", pv, "ckpt-uri");

        assertEq(reg.highestFinalizedBatchNumber(), 3);
        (bytes32 h, uint256 num) = reg.getLastCheckpoint();
        assertEq(h, hashes[3]);
        assertEq(num, 3);
        assertEq(dispatcher.count(), 3);
        for (uint256 n = 1; n <= 3; n++) {
            assertEq(dispatcher.dispatched(n - 1), hashes[n]);
            assertTrue(reg.isBatchFinalized(hashes[n]));
            assertTrue(reg.getBatchInfo(hashes[n]).feeDispatched);
        }

        // The next checkpoint chains from the previous end.
        _commit(address(reg), 2);
        reg.finalizeCheckpoint("p", _pv(3, 5), "uri");
        assertEq(reg.highestFinalizedBatchNumber(), 5);
        assertEq(dispatcher.count(), 5);
    }

    function test_FinalizeCheckpoint_SkipsBatchesAlreadyFinalized() public {
        _commit(address(reg), 3);
        skip(WINDOW);
        reg.finalizeBatch(hashes[1]);

        reg.finalizeCheckpoint("p", _pv(0, 3), "uri");

        assertEq(reg.highestFinalizedBatchNumber(), 3);
        assertEq(dispatcher.count(), 3); // batch 1 once (window), then 2 and 3
        assertEq(dispatcher.dispatched(0), hashes[1]);
        assertEq(dispatcher.dispatched(1), hashes[2]);
        assertEq(dispatcher.dispatched(2), hashes[3]);
    }

    function test_FinalizeCheckpoint_RangeAllFinalizedOnlyMovesTheCheckpoint() public {
        _commit(address(reg), 2);
        skip(WINDOW);
        reg.finalizeBatch(hashes[1]);
        reg.finalizeBatch(hashes[2]);

        vm.recordLogs();
        reg.finalizeCheckpoint("p", _pv(0, 2), "uri");
        assertEq(vm.getRecordedLogs().length, 1); // CheckpointFinalized only
        assertEq(reg.lastCheckpointBatchHash(), hashes[2]);
        assertEq(dispatcher.count(), 2);
    }

    function test_FinalizeCheckpoint_ClearsChallengeAndCreditsBondToSequencer() public {
        _commit(address(reg), 2);
        vm.deal(challenger, BOND);
        vm.prank(challenger);
        reg.challengeBatch{value: BOND}(hashes[2]);
        assertEq(reg.totalActiveBonds(), BOND);

        vm.expectEmit(true, true, false, true, address(reg));
        emit ChallengeResolved(2, true, BOND);
        reg.finalizeCheckpoint("p", _pv(0, 2), "uri");

        BatchRegistry.BatchInfo memory b = reg.getBatchInfo(hashes[2]);
        assertTrue(b.isFinalized);
        assertFalse(b.isChallenged);
        assertEq(b.challengeBondAmount, 0);
        assertEq(reg.totalActiveBonds(), 0);
        assertEq(reg.pendingWithdrawals(sequencer), BOND);
        assertEq(reg.pendingWithdrawals(challenger), 0);
        assertEq(reg.totalPendingWithdrawals(), BOND);

        vm.prank(sequencer);
        reg.claimWithdrawal();
        assertEq(sequencer.balance, BOND);
    }

    function test_FinalizeCheckpoint_RangeAtMaximum() public {
        _commit(address(reg), MAX_BATCHES);
        reg.finalizeCheckpoint("p", _pv(0, MAX_BATCHES), "uri");
        assertEq(reg.highestFinalizedBatchNumber(), MAX_BATCHES);
    }

    function test_FinalizeCheckpoint_PermissionlessCaller() public {
        _commit(address(reg), 1);
        vm.prank(makeAddr("anyone"));
        reg.finalizeCheckpoint("p", _pv(0, 1), "uri");
        assertTrue(reg.isBatchFinalized(hashes[1]));
    }

    /// @dev The C4 checkpoint test vector (smarttoken services/proofs/testdata/checkpoint-v4/vector.json):
    ///      a fresh deployment, two V4 mint batches, one checkpoint over (0, 2]. The program and the
    ///      contract must agree on these bytes.
    function test_FinalizeCheckpoint_C4Vector() public {
        bytes32 c1 = 0x7288c2f59c9f90ff0efa49d34d77972f735bffd43d9f2ac2c71305f172b035f8;
        bytes32 r1 = 0xabb532076137fa26ea9e3c38cc02a4575bfd827bcceadd3f186b654da23f7c5e;
        bytes32 h1 = 0x0681054a910ddf7bc0c17e49af468093d0636b87d6836b43973a372b29ae7960;
        bytes32 c2 = 0x2851663fb8e2d1ddaa6f00ebc9dd80bc7c8648eb5f94f9a3c946268dc057143c;
        bytes32 r2 = 0x2d2bafbe45cc5531d13f26efcf08a0d6ddf538b2edb2e6a6a9b6934de4afdd20;
        bytes32 h2 = 0xcd110cafc1aff2fac10f3ffd2c93ccf6790d46664ae3b96de2c2d5625a059ab9;
        bytes memory pv =
            hex"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cd110cafc1aff2fac10f3ffd2c93ccf6790d46664ae3b96de2c2d5625a059ab972a42af0875ef69720b84a1556b18f8d56473a963339827c7666ec228279cf96";

        vm.startPrank(sequencer);
        reg.commitBatch(bytes32(0), c1, r1, "uri", FEE);
        reg.commitBatch(h1, c2, r2, "uri", FEE);
        vm.stopPrank();
        assertEq(reg.batchHashByNumber(1), h1);
        assertEq(reg.batchHashByNumber(2), h2);

        // A one-byte change of rootsDigest (the last byte) reverts.
        bytes memory bad = bytes.concat(pv);
        bad[127] = bytes1(uint8(bad[127]) ^ 0x01);
        vm.expectRevert(BatchRegistry.InvalidProof.selector);
        reg.finalizeCheckpoint("p", bad, "uri");

        reg.finalizeCheckpoint("p", pv, "uri");
        assertTrue(reg.isBatchFinalized(h1));
        assertTrue(reg.isBatchFinalized(h2));
        assertEq(reg.lastCheckpointBatchHash(), h2);
        assertEq(reg.highestFinalizedBatchNumber(), 2);
    }

    // ── finalizeCheckpoint: refusals ──────────────────────────────────────────

    function test_FinalizeCheckpoint_RevertsOnWrongStartHash() public {
        _commit(address(reg), 2);
        {
            bytes memory pv = _pv(1, 2);
            vm.expectRevert(BatchRegistry.ChainBroken.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
    }

    function test_FinalizeCheckpoint_RevertsOnUnknownEndHash() public {
        _commit(address(reg), 1);
        bytes memory pv = abi.encode(bytes32(0), bytes32(0), keccak256("unknown"), bytes32(0));
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.finalizeCheckpoint("p", pv, "uri");
    }

    function test_FinalizeCheckpoint_RevertsOnEarlierOrEqualEndHash() public {
        _commit(address(reg), 3);
        reg.finalizeCheckpoint("p", _pv(0, 2), "uri");

        {
            bytes memory pv = _pv(2, 2);
            vm.expectRevert(BatchRegistry.InvalidInput.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.finalizeCheckpoint("p", abi.encode(hashes[2], _root(2), hashes[1], _root(1)), "uri");
    }

    function test_FinalizeCheckpoint_RevertsOnWrongStartIntegrityRoot() public {
        _commit(address(reg), 2);
        reg.finalizeCheckpoint("p", _pv(0, 1), "uri");
        {
            bytes memory pv = abi.encode(hashes[1], keccak256("wrong"), hashes[2], _digest(1, 2));
            vm.expectRevert(BatchRegistry.InvalidProof.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
    }

    function test_FinalizeCheckpoint_RevertsOnWrongRootsDigest() public {
        _commit(address(reg), 3);
        // A digest that differs in the middle root, and one that leaves the end root out.
        bytes32 wrongMiddle = sha256(abi.encodePacked(_root(1), keccak256("wrong"), _root(3)));
        {
            bytes memory pv = abi.encode(bytes32(0), bytes32(0), hashes[3], wrongMiddle);
            vm.expectRevert(BatchRegistry.InvalidProof.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
        {
            bytes memory pv = abi.encode(bytes32(0), bytes32(0), hashes[3], _digest(0, 2));
            vm.expectRevert(BatchRegistry.InvalidProof.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
    }

    /// @dev The sequencer anchored batch 2 with a root that the proof does not produce: the
    ///      checkpoint over it reverts, and the challenge resolves as fraud.
    function test_FinalizeCheckpoint_RevertsOnChallengedFraudBatchAndResolveDecides() public {
        _commit(address(reg), 1);
        bytes32 c2 = keccak256(abi.encode("c", uint256(2)));
        vm.prank(sequencer);
        reg.commitBatch(hashes[1], c2, keccak256("lie"), "uri", FEE);
        hashes.push(sha256(abi.encodePacked(hashes[1], c2)));
        vm.deal(challenger, BOND);
        vm.prank(challenger);
        reg.challengeBatch{value: BOND}(hashes[2]);

        {
            bytes memory pv = _pv(0, 2);
            vm.expectRevert(BatchRegistry.InvalidProof.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
        assertTrue(reg.getBatchInfo(hashes[2]).isChallenged);

        reg.resolveChallenge(hashes[2], "p", abi.encode(hashes[1], c2, _root(2)));
        assertEq(reg.pendingWithdrawals(challenger), BOND);
        assertEq(reg.pendingWithdrawals(sequencer), 0);
        assertFalse(reg.getBatchInfo(hashes[2]).isFinalized);
        assertTrue(reg.paused());
    }

    function test_FinalizeCheckpoint_RevertsOnFinalizedBatchAboveTheTip() public {
        _commit(address(reg), 2);
        skip(WINDOW);
        reg.finalizeBatch(hashes[1]);
        reg.finalizeBatch(hashes[2]);
        // An owner rewrite lowers the finalized tip below finalized batches.
        vm.startPrank(owner);
        reg.pause();
        reg.setBatchState(hashes[2], _root(2), 0);
        reg.unpause();
        vm.stopPrank();
        {
            bytes memory pv = _pv(0, 2);
            vm.expectRevert(BatchRegistry.ChainBroken.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
    }

    function test_FinalizeCheckpoint_RevertsAboveMaxCheckpointBatches() public {
        _commit(address(reg), MAX_BATCHES + 1);
        {
            bytes memory pv = _pv(0, MAX_BATCHES + 1);
            vm.expectRevert(BatchRegistry.CheckpointRangeTooLong.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
    }

    function test_FinalizeCheckpoint_RevertsOnBadProof() public {
        _commit(address(reg), 1);
        verifier.setRevert(true);
        {
            bytes memory pv = _pv(0, 1);
            vm.expectRevert(bytes("bad proof"));
            reg.finalizeCheckpoint("p", pv, "uri");
        }
    }

    function test_FinalizeCheckpoint_RevertsWhenPaused() public {
        _commit(address(reg), 1);
        vm.prank(owner);
        reg.pause();
        {
            bytes memory pv = _pv(0, 1);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
    }

    function test_FinalizeCheckpoint_RevertsWhenCheckpointAheadOfFinalized() public {
        _commit(address(reg), 3);
        // An owner rewrite puts the checkpoint start past the finalized tip.
        vm.startPrank(owner);
        reg.pause();
        reg.setCheckpointState(hashes[2], 2);
        reg.unpause();
        vm.stopPrank();
        {
            bytes memory pv = _pv(2, 3);
            vm.expectRevert(BatchRegistry.ChainBroken.selector);
            reg.finalizeCheckpoint("p", pv, "uri");
        }
    }

    function test_RecordCheckpoint_RevertsAfterUpgrade() public {
        vm.expectRevert(BatchRegistry.UseFinalizeCheckpoint.selector);
        reg.recordCheckpoint("p", abi.encode(bytes32(0), bytes32(0)), "uri");
    }

    // ── bond floor and checkpoint bound ───────────────────────────────────────

    function test_SetMinChallengeBond() public {
        vm.expectEmit(false, false, false, true, address(reg));
        emit MinChallengeBondUpdated(MIN_BOND, 20 ether);
        vm.prank(owner);
        reg.setMinChallengeBond(20 ether);
        assertEq(reg.minChallengeBond(), 20 ether);

        vm.prank(owner);
        vm.expectRevert(BatchRegistry.BondBelowMinimum.selector);
        reg.setMinChallengeBond(BOND + 1); // above the current bond

        vm.prank(owner);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.setMinChallengeBond(0);

        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, challenger));
        reg.setMinChallengeBond(1 ether);
    }

    function test_ChallengeBatch_AtTheNewFloor() public {
        vm.prank(owner);
        reg.setChallengeConfig(WINDOW, MIN_BOND);
        vm.prank(owner);
        vm.expectRevert(BatchRegistry.BondBelowMinimum.selector);
        reg.setChallengeConfig(WINDOW, MIN_BOND - 1);

        _commit(address(reg), 1);
        vm.deal(challenger, MIN_BOND);
        vm.prank(challenger);
        vm.expectRevert(BatchRegistry.BondTooLow.selector);
        reg.challengeBatch{value: MIN_BOND - 1}(hashes[1]);
        vm.prank(challenger);
        reg.challengeBatch{value: MIN_BOND}(hashes[1]);
        assertTrue(reg.getBatchInfo(hashes[1]).isChallenged);
        assertEq(reg.totalActiveBonds(), MIN_BOND);
    }

    function test_SetMaxCheckpointBatches() public {
        vm.expectEmit(false, false, false, true, address(reg));
        emit MaxCheckpointBatchesUpdated(MAX_BATCHES, 7);
        vm.prank(owner);
        reg.setMaxCheckpointBatches(7);
        assertEq(reg.maxCheckpointBatches(), 7);

        vm.prank(owner);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.setMaxCheckpointBatches(0);

        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, challenger));
        reg.setMaxCheckpointBatches(9);
    }

    function test_Commit_WritesBatchHashByNumber() public {
        _commit(address(reg), 2);
        assertEq(reg.batchHashByNumber(1), hashes[1]);
        assertEq(reg.batchHashByNumber(2), hashes[2]);
    }

    // ── upgrade from V1 ───────────────────────────────────────────────────────

    /// @dev A V1 proxy with 4 batches: 1 and 2 finalized by the window, a phase A checkpoint to
    ///      batch 2, batch 3 challenged, batch 4 pending.
    function _v1Proxy() internal returns (BatchRegistryV1 v1) {
        v1 = BatchRegistryV1(payable(address(new ERC1967Proxy(address(new BatchRegistryV1()), _initDataV1()))));
        vm.prank(owner);
        v1.setFeeDispatcher(address(dispatcher));
        _commit(address(v1), 2);
        skip(WINDOW);
        v1.finalizeBatch(hashes[1]);
        v1.finalizeBatch(hashes[2]);
        v1.recordCheckpoint("p", abi.encode(bytes32(0), hashes[2]), "uri");
        _commit(address(v1), 2);
        vm.deal(challenger, BOND);
        vm.prank(challenger);
        v1.challengeBatch{value: BOND}(hashes[3]);
    }

    function _initDataV1() internal view returns (bytes memory) {
        return
            abi.encodeCall(BatchRegistryV1.initialize, (owner, sequencer, address(verifier), FRAUD, CKPT, WINDOW, BOND));
    }

    function _pending(uint256 from, uint256 to) internal view returns (bytes32[] memory p) {
        p = new bytes32[](to + 1 - from);
        for (uint256 n = from; n <= to; n++) {
            p[n - from] = hashes[n];
        }
    }

    function _upgrade(BatchRegistryV1 v1, bytes32[] memory pending) internal {
        address impl = address(new BatchRegistry());
        vm.prank(owner);
        v1.upgradeToAndCall(
            impl, abi.encodeCall(BatchRegistry.reinitializeCheckpoints, (pending, MIN_BOND, MAX_BATCHES))
        );
    }

    function test_Upgrade_BackfillsPendingBatchesAndEmitsStart() public {
        hashes = [bytes32(0)];
        BatchRegistryV1 v1 = _v1Proxy();

        vm.expectEmit(true, false, false, true, address(v1));
        emit FinalizingCheckpointsStarted(hashes[2], 2);
        _upgrade(v1, _pending(3, 4));

        BatchRegistry r = BatchRegistry(payable(address(v1)));
        assertEq(r.batchHashByNumber(1), bytes32(0));
        assertEq(r.batchHashByNumber(2), bytes32(0));
        assertEq(r.batchHashByNumber(3), hashes[3]);
        assertEq(r.batchHashByNumber(4), hashes[4]);
        assertEq(r.minChallengeBond(), MIN_BOND);
        assertEq(r.maxCheckpointBatches(), MAX_BATCHES);

        // The first finalizing checkpoint starts at the phase A end and finalizes 3 (challenged) and 4.
        r.finalizeCheckpoint("p", _pv(2, 4), "uri");
        assertEq(r.highestFinalizedBatchNumber(), 4);
        assertEq(r.pendingWithdrawals(sequencer), BOND);
        assertEq(dispatcher.count(), 4);

        // New commits chain on and get an entry.
        _commit(address(r), 1);
        assertEq(r.batchHashByNumber(5), hashes[5]);
    }

    function test_UpgradeScript_UpgradesAndReinitializes() public {
        hashes = [bytes32(0)];
        BatchRegistryV1 v1 = _v1Proxy();
        vm.setEnv("BATCH_REGISTRY_PROXY_ADDRESS", vm.toString(address(v1)));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(owner));
        vm.setEnv("PENDING_BATCH_HASHES", string.concat(vm.toString(hashes[3]), ",", vm.toString(hashes[4])));
        vm.setEnv("MIN_CHALLENGE_BOND", vm.toString(MIN_BOND));
        vm.setEnv("MAX_CHECKPOINT_BATCHES", vm.toString(MAX_BATCHES));

        new UpgradeBatchRegistry().run();

        BatchRegistry r = BatchRegistry(payable(address(v1)));
        assertEq(r.batchHashByNumber(4), hashes[4]);
        assertEq(r.minChallengeBond(), MIN_BOND);
        assertEq(r.maxCheckpointBatches(), MAX_BATCHES);
    }

    function test_Upgrade_RefusesWrongBatchNumberOrCount() public {
        hashes = [bytes32(0)];
        BatchRegistryV1 v1 = _v1Proxy();
        address impl = address(new BatchRegistry());

        bytes32[] memory swapped = new bytes32[](2);
        swapped[0] = hashes[4];
        swapped[1] = hashes[3];
        vm.prank(owner);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        v1.upgradeToAndCall(
            impl, abi.encodeCall(BatchRegistry.reinitializeCheckpoints, (swapped, MIN_BOND, MAX_BATCHES))
        );

        vm.prank(owner);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        v1.upgradeToAndCall(
            impl, abi.encodeCall(BatchRegistry.reinitializeCheckpoints, (_pending(3, 3), MIN_BOND, MAX_BATCHES))
        );

        bytes32[] memory unknown = _pending(3, 4);
        unknown[1] = keccak256("unknown");
        vm.prank(owner);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        v1.upgradeToAndCall(
            impl, abi.encodeCall(BatchRegistry.reinitializeCheckpoints, (unknown, MIN_BOND, MAX_BATCHES))
        );
    }

    /// @dev Without a phase A checkpoint at the tip, the backfill starts after the last checkpoint
    ///      and the first finalizing checkpoint proves the finalized batches again.
    function test_Upgrade_CheckpointBehindFinalized() public {
        hashes = [bytes32(0)];
        BatchRegistryV1 v1 =
            BatchRegistryV1(payable(address(new ERC1967Proxy(address(new BatchRegistryV1()), _initDataV1()))));
        vm.prank(owner);
        v1.setFeeDispatcher(address(dispatcher));
        _commit(address(v1), 2);
        skip(WINDOW);
        v1.finalizeBatch(hashes[1]); // no phase A checkpoint reaches batch 1

        vm.expectEmit(true, false, false, true, address(v1));
        emit FinalizingCheckpointsStarted(bytes32(0), 0);
        _upgrade(v1, _pending(1, 2));

        BatchRegistry r = BatchRegistry(payable(address(v1)));
        r.finalizeCheckpoint("p", _pv(0, 2), "uri");
        assertEq(r.highestFinalizedBatchNumber(), 2);
        assertEq(dispatcher.count(), 2); // batch 1 by the window, batch 2 by the checkpoint
    }

    function test_FinalizeCheckpoint_RevertsOnMissingBatchHashEntry() public {
        hashes = [bytes32(0)];
        BatchRegistryV1 v1 = _v1Proxy();
        _upgrade(v1, _pending(3, 4));
        BatchRegistry r = BatchRegistry(payable(address(v1)));
        // An owner rewrite moves the checkpoint back to batch 1; batch 2 has no entry.
        vm.startPrank(owner);
        r.pause();
        r.setCheckpointState(hashes[1], 1);
        r.unpause();
        vm.stopPrank();
        {
            bytes memory pv = _pv(1, 4);
            vm.expectRevert(BatchRegistry.ChainBroken.selector);
            r.finalizeCheckpoint("p", pv, "uri");
        }
    }

    function test_Upgrade_RefusesFloorAboveBond() public {
        hashes = [bytes32(0)];
        BatchRegistryV1 v1 = _v1Proxy();
        address impl = address(new BatchRegistry());
        vm.prank(owner);
        vm.expectRevert(BatchRegistry.BondBelowMinimum.selector);
        v1.upgradeToAndCall(
            impl, abi.encodeCall(BatchRegistry.reinitializeCheckpoints, (_pending(3, 4), BOND + 1, MAX_BATCHES))
        );
    }

    function test_Reinitialize_RunsOnceAndOnlyForOwner() public {
        vm.prank(owner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        reg.reinitializeCheckpoints(new bytes32[](0), MIN_BOND, MAX_BATCHES);

        BatchRegistry fresh =
            BatchRegistry(payable(address(new ERC1967Proxy(address(new BatchRegistry()), _initData()))));
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, challenger));
        fresh.reinitializeCheckpoints(new bytes32[](0), MIN_BOND, MAX_BATCHES);
    }

    /// @dev Every V1 slot keeps its value; only the three new variables taken from `__gap`
    ///      (slots 18-20) change, and the OpenZeppelin namespaced slots keep theirs except the
    ///      initialized version.
    function test_Upgrade_KeepsEveryStorageSlot() public {
        hashes = [bytes32(0)];
        BatchRegistryV1 v1 = _v1Proxy();
        vm.prank(owner);
        v1.setChallengeConfig(2 hours, BOND); // a non-default value in slot 0
        address proxy = address(v1);

        bytes32[] memory namespaced = new bytes32[](4);
        namespaced[0] = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300; // Ownable
        namespaced[1] = 0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00; // Ownable2Step
        namespaced[2] = 0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300; // Pausable
        namespaced[3] = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00; // ReentrancyGuard
        bytes32 initializable = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

        bytes32[51] memory before;
        for (uint256 i = 0; i < 51; i++) {
            before[i] = vm.load(proxy, bytes32(i));
        }
        bytes32[] memory nsBefore = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            nsBefore[i] = vm.load(proxy, namespaced[i]);
        }
        BatchRegistryV1.BatchInfo[5] memory infos;
        for (uint256 n = 1; n <= 4; n++) {
            infos[n] = v1.getBatchInfo(hashes[n]);
        }

        _upgrade(v1, _pending(3, 4));
        BatchRegistry r = BatchRegistry(payable(proxy));

        for (uint256 i = 0; i < 51; i++) {
            if (i == 19) assertEq(uint256(vm.load(proxy, bytes32(i))), MIN_BOND, "minChallengeBond slot");
            else if (i == 20) assertEq(uint256(vm.load(proxy, bytes32(i))), MAX_BATCHES, "maxCheckpointBatches slot");
            else assertEq(vm.load(proxy, bytes32(i)), before[i], "slot changed");
        }
        for (uint256 i = 0; i < 4; i++) {
            assertEq(vm.load(proxy, namespaced[i]), nsBefore[i], "namespaced slot changed");
        }
        assertEq(uint256(vm.load(proxy, initializable)), 2);
        // The mapping at slot 18 is batchHashByNumber.
        assertEq(vm.load(proxy, keccak256(abi.encode(uint256(3), uint256(18)))), hashes[3]);

        for (uint256 n = 1; n <= 4; n++) {
            BatchRegistry.BatchInfo memory a = r.getBatchInfo(hashes[n]);
            assertEq(a.integrityRoot, infos[n].integrityRoot);
            assertEq(a.batchNumber, infos[n].batchNumber);
            assertEq(a.timestamp, infos[n].timestamp);
            assertEq(a.challenger, infos[n].challenger);
            assertEq(a.challengeBondAmount, infos[n].challengeBondAmount);
            assertEq(a.fee, infos[n].fee);
            assertEq(a.isFinalized, infos[n].isFinalized);
            assertEq(a.isChallenged, infos[n].isChallenged);
            assertEq(a.feeDispatched, infos[n].feeDispatched);
        }
        assertEq(r.owner(), owner);
        assertEq(r.challengeWindow(), 2 hours);
        assertEq(r.challengeBond(), BOND);
        assertEq(r.totalActiveBonds(), BOND);
        assertEq(r.lastCheckpointBatchHash(), hashes[2]);
        assertEq(r.lastCheckpointBatchNumber(), 2);
    }
}
