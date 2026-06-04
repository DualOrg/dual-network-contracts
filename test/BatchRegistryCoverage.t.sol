// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";
import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";
import {IFeeDispatcher} from "../src/interfaces/IFeeDispatcher.sol";

contract CovVerifier is ISP1Verifier {
    bool public shouldRevert;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function verifyProof(bytes32, bytes calldata, bytes calldata) external view override {
        if (shouldRevert) revert("bad proof");
    }
}

contract CovReject {
    receive() external payable {
        revert("no");
    }
}

contract CovDispatcher is IFeeDispatcher {
    uint8 public mode; // 0 = ok, 1 = returns false, 2 = reverts

    function setMode(uint8 m) external {
        mode = m;
    }

    function dispatchFee(bytes32, uint256) external view override returns (bool) {
        if (mode == 2) revert("revert");
        return mode == 0;
    }

    function dispatchLedgerFee(bytes32, uint256) external payable override returns (bool) {
        return true;
    }
}

/// @dev Challenger that rejects native, to exercise claimWithdrawal's restore path.
contract CovRejectingChallenger {
    BatchRegistry public reg;

    function setReg(BatchRegistry _r) external {
        reg = _r;
    }

    function challenge(bytes32 bh, uint256 bond) external {
        reg.challengeBatch{value: bond}(bh);
    }

    function claim() external {
        reg.claimWithdrawal();
    }

    receive() external payable {
        revert("reject");
    }
}

/// @dev Targeted branch coverage for BatchRegistry revert/config paths.
contract BatchRegistryCoverageTest is Test {
    BatchRegistry internal reg;
    CovVerifier internal verifier;

    address internal owner = makeAddr("owner");
    address internal sequencer = makeAddr("sequencer");
    address internal challenger = makeAddr("challenger");

    uint256 internal constant WINDOW = 1 hours;
    uint256 internal constant BOND = 100_000 ether;
    bytes32 internal constant FRAUD = keccak256("fraud");
    bytes32 internal constant CKPT = keccak256("ckpt");

    function setUp() public {
        vm.warp(1_000_000);
        verifier = new CovVerifier();
        BatchRegistry impl = new BatchRegistry();
        reg = BatchRegistry(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            BatchRegistry.initialize,
                            (owner, sequencer, address(verifier), FRAUD, CKPT, WINDOW, BOND)
                        )
                    )
                )
            )
        );
    }

    function _commit(bytes32 prev, bytes32 c, uint256 fee) internal returns (bytes32) {
        vm.prank(sequencer);
        reg.commitBatch(prev, c, keccak256("root"), "uri", fee);
        return sha256(abi.encodePacked(prev, c));
    }

    // ── initialize guards ─────────────────────────────────────────────────────

    function test_Init_Reverts() public {
        BatchRegistry impl = new BatchRegistry();
        bytes memory base = abi.encodeCall(
            BatchRegistry.initialize, (owner, sequencer, address(verifier), FRAUD, CKPT, WINDOW, BOND)
        );
        base; // silence
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(BatchRegistry.initialize, (address(0), sequencer, address(verifier), FRAUD, CKPT, WINDOW, BOND))
        );
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(BatchRegistry.initialize, (owner, address(0), address(verifier), FRAUD, CKPT, WINDOW, BOND))
        );
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(BatchRegistry.initialize, (owner, sequencer, address(0), FRAUD, CKPT, WINDOW, BOND))
        );
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(BatchRegistry.initialize, (owner, sequencer, address(verifier), FRAUD, CKPT, 0, BOND))
        );
        vm.expectRevert(BatchRegistry.BondBelowMinimum.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(BatchRegistry.initialize, (owner, sequencer, address(verifier), FRAUD, CKPT, WINDOW, 1 ether))
        );
    }

    // ── commit / proof guards ─────────────────────────────────────────────────

    function test_Commit_RevertsForNonSequencer() public {
        vm.expectRevert(BatchRegistry.Unauthorized.selector);
        reg.commitBatch(bytes32(0), keccak256("c"), keccak256("r"), "uri", 0);
    }

    function test_CommitWithProof_Guards() public {
        bytes memory pv = abi.encode(bytes32(0), keccak256("c"), keccak256("r"));
        // InvalidInput (zero commitment)
        vm.prank(sequencer);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.commitBatchWithProof(bytes32(0), bytes32(0), keccak256("r"), "p", pv, "uri", 0);
        // EmptyDataURI
        vm.prank(sequencer);
        vm.expectRevert(BatchRegistry.EmptyDataURI.selector);
        reg.commitBatchWithProof(bytes32(0), keccak256("c"), keccak256("r"), "p", pv, "", 0);
        // ChainBroken
        vm.prank(sequencer);
        vm.expectRevert(BatchRegistry.ChainBroken.selector);
        reg.commitBatchWithProof(keccak256("x"), keccak256("c"), keccak256("r"), "p", pv, "uri", 0);
        // InvalidProof (public values mismatch)
        bytes memory badPv = abi.encode(bytes32(0), keccak256("other"), keccak256("r"));
        vm.prank(sequencer);
        vm.expectRevert(BatchRegistry.InvalidProof.selector);
        reg.commitBatchWithProof(bytes32(0), keccak256("c"), keccak256("r"), "p", badPv, "uri", 0);
    }

    function test_CommitWithProof_FinalizesAndDispatchesNoFee() public {
        bytes memory pv = abi.encode(bytes32(0), keccak256("c"), keccak256("r"));
        vm.prank(sequencer);
        reg.commitBatchWithProof(bytes32(0), keccak256("c"), keccak256("r"), "p", pv, "uri", 0);
        bytes32 bh = sha256(abi.encodePacked(bytes32(0), keccak256("c")));
        assertTrue(reg.getBatchInfo(bh).isFinalized);
        assertTrue(reg.getBatchInfo(bh).feeDispatched); // fee == 0 path
    }

    function test_Finalize_NoDispatcherParksFee() public {
        // No fee dispatcher set → finalized fee batch parks pendingFeeDispatch.
        bytes32 bh = _commit(bytes32(0), keccak256("c"), 5 ether);
        vm.warp(block.timestamp + WINDOW + 1);
        reg.finalizeBatch(bh);
        assertEq(reg.pendingFeeDispatch(bh), 5 ether);
    }

    // ── challenge / resolve / finalize guards ─────────────────────────────────

    function test_Challenge_Guards() public {
        bytes32 bh = _commit(bytes32(0), keccak256("c"), 0);
        // Unknown batch
        vm.deal(challenger, BOND);
        vm.prank(challenger);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.challengeBatch{value: BOND}(keccak256("nope"));
        // Bond too low
        vm.deal(challenger, BOND);
        vm.prank(challenger);
        vm.expectRevert(BatchRegistry.BondTooLow.selector);
        reg.challengeBatch{value: BOND - 1}(bh);
        // Window closed
        vm.warp(block.timestamp + WINDOW + 1);
        vm.deal(challenger, BOND);
        vm.prank(challenger);
        vm.expectRevert(BatchRegistry.ChallengePeriodActive.selector);
        reg.challengeBatch{value: BOND}(bh);
    }

    function test_Resolve_RevertsWhenNotChallenged() public {
        bytes32 bh = _commit(bytes32(0), keccak256("c"), 0);
        bytes memory pv = abi.encode(bytes32(0), keccak256("c"), keccak256("root"));
        vm.expectRevert(BatchRegistry.BatchNotChallenged.selector);
        reg.resolveChallenge(bh, "p", pv);
    }

    function test_Finalize_Guards() public {
        bytes32 bh = _commit(bytes32(0), keccak256("c"), 0);
        // Too early
        vm.expectRevert(BatchRegistry.ChallengePeriodActive.selector);
        reg.finalizeBatch(bh);
        // Unknown
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.finalizeBatch(keccak256("nope"));
        // Finalize then re-finalize
        vm.warp(block.timestamp + WINDOW + 1);
        reg.finalizeBatch(bh);
        vm.expectRevert(BatchRegistry.AlreadyFinalized.selector);
        reg.finalizeBatch(bh);
    }

    function test_RetryDispatch_RevertsWhenNoPending() public {
        vm.expectRevert(BatchRegistry.NoPendingDispatch.selector);
        reg.retryDispatchFee(keccak256("x"));
    }

    function test_Claim_RevertsWhenNothing() public {
        vm.expectRevert(BatchRegistry.NothingToClaim.selector);
        reg.claimWithdrawal();
    }

    // ── checkpoint guards ─────────────────────────────────────────────────────

    function test_RecordCheckpoint_Guards() public {
        // endBatch unknown → InvalidInput
        bytes memory pv = abi.encode(bytes32(0), keccak256("end"));
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.recordCheckpoint("p", pv, "uri");

        // endBatch exists but not finalized → NotFinalized
        bytes32 bh = _commit(bytes32(0), keccak256("c"), 0);
        bytes memory pv2 = abi.encode(bytes32(0), bh);
        vm.expectRevert(BatchRegistry.NotFinalized.selector);
        reg.recordCheckpoint("p", pv2, "uri");
    }

    // ── admin guards ──────────────────────────────────────────────────────────

    function test_Admin_Guards() public {
        vm.startPrank(owner);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.setSequencer(address(0));
        vm.expectRevert(BatchRegistry.UnchangedValue.selector);
        reg.setSequencer(sequencer);

        vm.expectRevert(BatchRegistry.UnchangedValue.selector);
        reg.setFeeDispatcher(address(0)); // already address(0)

        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.setChallengeConfig(0, BOND);
        vm.expectRevert(BatchRegistry.BondBelowMinimum.selector);
        reg.setChallengeConfig(WINDOW, 1 ether);

        vm.expectRevert(BatchRegistry.UnchangedValue.selector);
        reg.setHaltOnFraud(true); // default true
        vm.stopPrank();
    }

    function test_EmergencyWithdraw_Guards() public {
        vm.startPrank(owner);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.emergencyWithdraw(payable(address(0)), 1);
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.emergencyWithdraw(payable(owner), 0);
        vm.expectRevert(BatchRegistry.NoSurplus.selector);
        reg.emergencyWithdraw(payable(owner), 1 ether); // no surplus
        vm.stopPrank();

        // With surplus: exceeds + success paths.
        vm.deal(address(reg), 3 ether);
        vm.startPrank(owner);
        vm.expectRevert(BatchRegistry.AmountExceedsSurplus.selector);
        reg.emergencyWithdraw(payable(owner), 4 ether);
        CovReject bad = new CovReject();
        vm.expectRevert(BatchRegistry.TransferFailed.selector);
        reg.emergencyWithdraw(payable(address(bad)), 1 ether);
        reg.emergencyWithdraw(payable(owner), 1 ether); // success
        vm.stopPrank();
        assertEq(owner.balance, 1 ether);
    }

    // ── retry dispatch: success / false / revert ──────────────────────────────

    function test_RetryDispatch_AllPaths() public {
        CovDispatcher disp = new CovDispatcher();
        bytes32 bh = _commit(bytes32(0), keccak256("c"), 5 ether);
        vm.warp(block.timestamp + WINDOW + 1);
        reg.finalizeBatch(bh); // no dispatcher → parks 5 ether
        assertEq(reg.pendingFeeDispatch(bh), 5 ether);

        vm.prank(owner);
        reg.setFeeDispatcher(address(disp));

        // Dispatcher reports false → re-parked.
        disp.setMode(1);
        reg.retryDispatchFee(bh);
        assertEq(reg.pendingFeeDispatch(bh), 5 ether);

        // Dispatcher reverts → re-parked (catch path).
        disp.setMode(2);
        reg.retryDispatchFee(bh);
        assertEq(reg.pendingFeeDispatch(bh), 5 ether);

        // Dispatcher succeeds → cleared + feeDispatched.
        disp.setMode(0);
        reg.retryDispatchFee(bh);
        assertEq(reg.pendingFeeDispatch(bh), 0);
        assertTrue(reg.getBatchInfo(bh).feeDispatched);
    }

    // ── resolve guards + checkpoint success ───────────────────────────────────

    function test_Resolve_InvalidInputAndProof() public {
        // Unknown batch.
        bytes memory pv = abi.encode(bytes32(0), keccak256("c"), keccak256("root"));
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.resolveChallenge(keccak256("nope"), "p", pv);

        // Challenge a real batch, then resolve with a hash-mismatched proof.
        bytes32 bh = _commit(bytes32(0), keccak256("c"), 0);
        vm.deal(challenger, BOND);
        vm.prank(challenger);
        reg.challengeBatch{value: BOND}(bh);

        bytes memory badPv = abi.encode(keccak256("x"), keccak256("y"), keccak256("root"));
        vm.expectRevert(BatchRegistry.InvalidProof.selector);
        reg.resolveChallenge(bh, "p", badPv);
    }

    function test_RecordCheckpoint_SuccessAndChain() public {
        bytes32 bh = _commit(bytes32(0), keccak256("c"), 0);
        skip(WINDOW + 1);
        reg.finalizeBatch(bh);

        bytes memory pv = abi.encode(bytes32(0), bh);
        reg.recordCheckpoint("p", pv, "uri");
        assertEq(reg.lastCheckpointBatchHash(), bh);

        // Second checkpoint must chain from the previous end hash.
        bytes32 bh2 = _commit(bh, keccak256("c2"), 0);
        skip(WINDOW + 1);
        reg.finalizeBatch(bh2);

        // Wrong start hash → ChainBroken.
        bytes memory badChain = abi.encode(keccak256("wrongstart"), bh2);
        vm.expectRevert(BatchRegistry.ChainBroken.selector);
        reg.recordCheckpoint("p", badChain, "uri");

        // Correct chain.
        bytes memory pv2 = abi.encode(bh, bh2);
        reg.recordCheckpoint("p", pv2, "uri");
        assertEq(reg.lastCheckpointBatchHash(), bh2);
    }

    // ── claim restore on failed send ──────────────────────────────────────────

    function test_Claim_RestoresOnFailedSend() public {
        CovRejectingChallenger atk = new CovRejectingChallenger();
        atk.setReg(reg);

        bytes32 bh = _commit(bytes32(0), keccak256("c"), 0);
        vm.deal(address(atk), BOND);
        atk.challenge(bh, BOND);

        // Fraud resolution credits the rejecting challenger.
        bytes memory pv = abi.encode(bytes32(0), keccak256("c"), keccak256("fraud"));
        reg.resolveChallenge(bh, "p", pv);
        assertEq(reg.pendingWithdrawals(address(atk)), BOND);

        // Claim fails on send → balance restored, totals intact.
        vm.expectRevert(BatchRegistry.TransferFailed.selector);
        atk.claim();
        assertEq(reg.pendingWithdrawals(address(atk)), BOND);
        assertEq(reg.totalPendingWithdrawals(), BOND);
    }

    function test_IsBatchFinalized_UnknownReturnsFalse() public view {
        assertFalse(reg.isBatchFinalized(keccak256("nope")));
    }

    function test_SetBatchState_And_CheckpointState() public {
        bytes32 bh = _commit(bytes32(0), keccak256("c"), 0);
        vm.startPrank(owner);
        reg.pause();
        // setBatchState with a known batch + matching integrity root.
        reg.setBatchState(bh, keccak256("root"), 1);
        assertEq(reg.lastBatchHash(), bh);
        // setBatchState mismatched integrity root → InvalidInput
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.setBatchState(bh, keccak256("wrong"), 1);
        // setCheckpointState mismatched batch number → InvalidInput
        vm.expectRevert(BatchRegistry.InvalidInput.selector);
        reg.setCheckpointState(bh, 999);
        vm.stopPrank();
    }
}
