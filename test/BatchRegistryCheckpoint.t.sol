// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";
import {BatchRegistryV1} from "../src/legacy/BatchRegistryV1.sol";
import {IFeeDispatcher} from "../src/interfaces/IFeeDispatcher.sol";
import {UpgradeBatchRegistry} from "../script/UpgradeBatchRegistry.s.sol";

/// @dev Accepts every proof for the checkpoint key unless told to fail.
contract CkptVerifier is ISP1Verifier {
    bool public shouldRevert;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function verifyProof(bytes32 vkey, bytes calldata, bytes calldata) external view override {
        if (shouldRevert) revert("bad proof");
        if (vkey != keccak256("ckpt")) revert("wrong vkey");
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

    function _pv(uint256 start, uint256 end) internal view returns (bytes memory) {
        return abi.encode(hashes[start], _root(start), hashes[end], _root(end));
    }

    // ── finalizeCheckpoint: effect ────────────────────────────────────────────

    function test_FinalizeCheckpoint_FinalizesRangeInOrderAndDispatchesFees() public {
        _commit(address(reg), 3);

        for (uint256 n = 1; n <= 3; n++) {
            vm.expectEmit(true, true, false, false, address(reg));
            emit BatchFinalized(n, hashes[n]);
        }
        vm.expectEmit(true, true, false, true, address(reg));
        emit CheckpointFinalized(hashes[0], hashes[3], 3, keccak256("p"), "ckpt-uri");
        reg.finalizeCheckpoint("p", _pv(0, 3), "ckpt-uri");

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

    // ── finalizeCheckpoint: refusals ──────────────────────────────────────────

    function test_FinalizeCheckpoint_RevertsOnWrongStartHash() public {
        _commit(address(reg), 2);
        vm.expectRevert(BatchRegistry.ChainBroken.selector);
        reg.finalizeCheckpoint("p", _pv(1, 2), "uri");
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

        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.finalizeCheckpoint("p", _pv(2, 2), "uri");
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.finalizeCheckpoint("p", abi.encode(hashes[2], _root(2), hashes[1], _root(1)), "uri");
    }

    function test_FinalizeCheckpoint_RevertsOnWrongStartIntegrityRoot() public {
        _commit(address(reg), 2);
        reg.finalizeCheckpoint("p", _pv(0, 1), "uri");
        vm.expectRevert(BatchRegistry.InvalidProof.selector);
        reg.finalizeCheckpoint("p", abi.encode(hashes[1], keccak256("wrong"), hashes[2], _root(2)), "uri");
    }

    function test_FinalizeCheckpoint_RevertsOnWrongEndIntegrityRoot() public {
        _commit(address(reg), 2);
        vm.expectRevert(BatchRegistry.InvalidProof.selector);
        reg.finalizeCheckpoint("p", abi.encode(bytes32(0), bytes32(0), hashes[2], keccak256("wrong")), "uri");
    }

    function test_FinalizeCheckpoint_RevertsAboveMaxCheckpointBatches() public {
        _commit(address(reg), MAX_BATCHES + 1);
        vm.expectRevert(BatchRegistry.CheckpointRangeTooLong.selector);
        reg.finalizeCheckpoint("p", _pv(0, MAX_BATCHES + 1), "uri");
    }

    function test_FinalizeCheckpoint_RevertsOnBadProof() public {
        _commit(address(reg), 1);
        verifier.setRevert(true);
        vm.expectRevert(bytes("bad proof"));
        reg.finalizeCheckpoint("p", _pv(0, 1), "uri");
    }

    function test_FinalizeCheckpoint_RevertsWhenPaused() public {
        _commit(address(reg), 1);
        vm.prank(owner);
        reg.pause();
        vm.expectRevert();
        reg.finalizeCheckpoint("p", _pv(0, 1), "uri");
    }

    function test_FinalizeCheckpoint_RevertsWhenCheckpointAheadOfFinalized() public {
        _commit(address(reg), 3);
        // An owner rewrite puts the checkpoint start past the finalized tip.
        vm.startPrank(owner);
        reg.pause();
        reg.setCheckpointState(hashes[2], 2);
        reg.unpause();
        vm.stopPrank();
        vm.expectRevert(BatchRegistry.ChainBroken.selector);
        reg.finalizeCheckpoint("p", _pv(2, 3), "uri");
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

        vm.prank(challenger);
        vm.expectRevert();
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
        vm.expectRevert();
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

    function test_Upgrade_RefusesCheckpointBehindFinalized() public {
        hashes = [bytes32(0)];
        BatchRegistryV1 v1 =
            BatchRegistryV1(payable(address(new ERC1967Proxy(address(new BatchRegistryV1()), _initDataV1()))));
        _commit(address(v1), 2);
        skip(WINDOW);
        v1.finalizeBatch(hashes[1]); // no phase A checkpoint reaches batch 1

        address impl = address(new BatchRegistry());
        vm.prank(owner);
        vm.expectRevert(BatchRegistry.CheckpointNotAtFinalized.selector);
        v1.upgradeToAndCall(
            impl, abi.encodeCall(BatchRegistry.reinitializeCheckpoints, (_pending(2, 2), MIN_BOND, MAX_BATCHES))
        );
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
        vm.expectRevert();
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
