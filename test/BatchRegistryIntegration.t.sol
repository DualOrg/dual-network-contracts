// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";
import {Vault} from "../src/Vault.sol";
import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";

contract MockVerifier is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure override {}
}

contract Sink {
    receive() external payable {}
}

/// @dev Challenger that re-enters claimWithdrawal on payout.
contract ReentrantChallenger {
    BatchRegistry public reg;
    bool public attempted;
    bool public blocked;

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
        if (!attempted && address(reg) != address(0)) {
            attempted = true;
            try reg.claimWithdrawal() {
                blocked = false;
            } catch {
                blocked = true;
            }
        }
    }
}

contract BatchRegistryIntegrationTest is Test {
    BatchRegistry internal reg;
    FeeDispatcher internal dispatcher;
    Vault internal vault;
    MockVerifier internal verifier;

    address internal owner = makeAddr("owner");
    address internal sequencer = makeAddr("sequencer");

    uint256 internal constant WINDOW = 1 hours;
    uint256 internal constant BOND = 100_000 ether;
    bytes32 internal constant FRAUD_VKEY = keccak256("fraud");

    function setUp() public {
        vm.warp(1_000_000);
        verifier = new MockVerifier();

        Vault vimpl = new Vault();
        vault = Vault(payable(address(new ERC1967Proxy(address(vimpl), abi.encodeCall(Vault.initialize, (owner))))));

        BatchRegistry rimpl = new BatchRegistry();
        reg = BatchRegistry(
            payable(
                address(
                    new ERC1967Proxy(
                        address(rimpl),
                        abi.encodeCall(
                            BatchRegistry.initialize,
                            (owner, sequencer, address(verifier), FRAUD_VKEY, keccak256("ckpt"), WINDOW, BOND)
                        )
                    )
                )
            )
        );

        FeeDispatcher fimpl = new FeeDispatcher();
        dispatcher = FeeDispatcher(
            payable(
                address(
                    new ERC1967Proxy(
                        address(fimpl),
                        abi.encodeCall(FeeDispatcher.initialize, (owner, address(vault), address(reg), makeAddr("ledger")))
                    )
                )
            )
        );

        vm.startPrank(owner);
        vault.setFeeDispatcher(address(dispatcher));
        reg.setFeeDispatcher(address(dispatcher));
        vm.stopPrank();
    }

    function _commitFinalizedBatch(bytes32 prev, bytes32 commitment, bytes32 root, uint256 fee)
        internal
        returns (bytes32)
    {
        bytes memory pv = abi.encode(prev, commitment, root);
        vm.prank(sequencer);
        reg.commitBatchWithProof(prev, commitment, root, "proof", pv, "uri", fee);
        return sha256(abi.encodePacked(prev, commitment));
    }

    // ── integration: finalized-batch fee flows BatchRegistry → Dispatcher → Vault

    function test_Integration_BatchFeeFlowsThroughDispatcherFromVault() public {
        Sink recipient = new Sink();
        vm.prank(owner);
        dispatcher.addRecipient(payable(address(recipient)), 10_000); // 100%

        // Fund the vault so the dispatcher can pull the batch fee.
        vm.deal(address(this), 5 ether);
        vault.depositDual{value: 5 ether}(keccak256("org"));

        // A proven batch finalizes immediately and dispatches its fee.
        bytes32 bh = _commitFinalizedBatch(bytes32(0), keccak256("c1"), keccak256("r1"), 2 ether);

        BatchRegistry.BatchInfo memory b = reg.getBatchInfo(bh);
        assertTrue(b.isFinalized, "not finalized");
        assertTrue(b.feeDispatched, "fee not dispatched");
        assertEq(address(recipient).balance, 2 ether);
        assertEq(address(vault).balance, 3 ether);
        assertEq(vault.totalWithdrawnForFees(), 2 ether);
    }

    // ── adversarial: fraud resolution pays challenger and halts ───────────────

    function test_Adversarial_FraudResolutionPaysChallengerAndPauses() public {
        // Commit an unproven batch so it can be challenged.
        vm.prank(sequencer);
        reg.commitBatch(bytes32(0), keccak256("c"), keccak256("honestRoot"), "uri", 0);
        bytes32 bh = sha256(abi.encodePacked(bytes32(0), keccak256("c")));

        address challenger = makeAddr("chal");
        vm.deal(challenger, BOND);
        vm.prank(challenger);
        reg.challengeBatch{value: BOND}(bh);
        assertEq(reg.totalActiveBonds(), BOND);

        // Resolve with a fraud proof (proved root != committed root).
        bytes memory pv = abi.encode(bytes32(0), keccak256("c"), keccak256("fraudRoot"));
        reg.resolveChallenge(bh, "proof", pv);

        // Challenger is made whole; contract halts (haltOnFraud default true).
        assertEq(reg.pendingWithdrawals(challenger), BOND);
        assertEq(reg.totalActiveBonds(), 0);
        assertTrue(reg.paused());

        // Challenger claims the bond back.
        vm.prank(challenger);
        reg.claimWithdrawal();
        assertEq(challenger.balance, BOND);
        assertEq(reg.totalPendingWithdrawals(), 0);
    }

    // ── adversarial: reentrancy on claim, and bond-protected surplus ──────────

    function test_Adversarial_ReentrantClaimNoDoubleSpend() public {
        ReentrantChallenger attacker = new ReentrantChallenger();
        attacker.setReg(reg);

        vm.prank(sequencer);
        reg.commitBatch(bytes32(0), keccak256("c"), keccak256("root"), "uri", 0);
        bytes32 bh = sha256(abi.encodePacked(bytes32(0), keccak256("c")));

        vm.deal(address(attacker), BOND);
        attacker.challenge(bh, BOND);

        // Fraud resolution credits the attacker's pending balance.
        bytes memory pv = abi.encode(bytes32(0), keccak256("c"), keccak256("fraud"));
        reg.resolveChallenge(bh, "proof", pv);

        attacker.claim();

        assertTrue(attacker.attempted(), "reentry path not exercised");
        assertTrue(attacker.blocked(), "reentrancy was NOT blocked");
        assertEq(address(attacker).balance, BOND); // paid exactly once
        assertEq(reg.totalPendingWithdrawals(), 0);
    }

    function test_Adversarial_EmergencyWithdrawCannotTouchBonds() public {
        vm.prank(sequencer);
        reg.commitBatch(bytes32(0), keccak256("c"), keccak256("root"), "uri", 0);
        bytes32 bh = sha256(abi.encodePacked(bytes32(0), keccak256("c")));

        address challenger = makeAddr("chal");
        vm.deal(challenger, BOND);
        vm.prank(challenger);
        reg.challengeBatch{value: BOND}(bh);

        // The escrowed bond is not surplus, so the owner cannot withdraw it.
        assertEq(reg.withdrawableSurplus(), 0);
        vm.prank(owner);
        vm.expectRevert(BatchRegistry.NoSurplus.selector);
        reg.emergencyWithdraw(payable(owner), 1 ether);
    }
}
