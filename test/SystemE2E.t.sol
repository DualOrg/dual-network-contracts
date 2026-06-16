// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../src/Vault.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";
import {Ledger} from "../src/Ledger.sol";
import {Staking} from "../src/StakingFinal.sol";
import {BridgedNFTs} from "../src/BridgedNFTs.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";
import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";

contract E2EVerifier is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure override {}
}

contract Treasury {
    receive() external payable {}
}

/// @title Full-system end-to-end tests.
/// @notice Deploys the entire protocol (Vault, FeeDispatcher, BatchRegistry,
///         Ledger, Staking, BridgedNFTs), wires the real topology, and drives
///         money through the complete pipeline. A global native-conservation
///         assertion is the backstop for integration-seam bugs.
contract SystemE2ETest is Test {
    Vault internal vault;
    FeeDispatcher internal dispatcher;
    BatchRegistry internal registry;
    Ledger internal ledger;
    Staking internal staking;
    BridgedNFTs internal nft;
    Treasury internal fdTreasury;
    Treasury internal ledgerTreasury;

    address internal owner = makeAddr("owner");
    address internal sequencer = makeAddr("sequencer");
    address internal partner = makeAddr("partner");
    address internal staker = makeAddr("staker");
    address internal staker2 = makeAddr("staker2");
    address internal nftUser = makeAddr("nftUser");

    uint256 internal constant REWARDS_DURATION = 7 days;
    uint256 internal constant CHALLENGE_WINDOW = 1 hours;
    uint256 internal constant CHALLENGE_BOND = 100_000 ether;

    // Total native deliberately injected into the system across a test.
    uint256 internal injected;

    function setUp() public {
        vm.warp(1_000_000);
        fdTreasury = new Treasury();
        ledgerTreasury = new Treasury();

        // 1. Vault
        vault = Vault(payable(_proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (owner)))));

        // 2. FeeDispatcher (batchRegistry/ledger rewired after they exist)
        dispatcher = FeeDispatcher(
            payable(
                _proxy(
                    address(new FeeDispatcher()),
                    abi.encodeCall(
                        FeeDispatcher.initialize, (owner, address(vault), makeAddr("phBatch"), makeAddr("phLedger"))
                    )
                )
            )
        );

        // 3. Staking (recipient of FeeDispatcher)
        staking = Staking(
            payable(
                _proxy(
                    address(new Staking()),
                    abi.encodeCall(Staking.initialize, (owner, address(dispatcher), REWARDS_DURATION))
                )
            )
        );

        // 4. BatchRegistry
        registry = BatchRegistry(
            payable(
                _proxy(
                    address(new BatchRegistry()),
                    abi.encodeCall(
                        BatchRegistry.initialize,
                        (owner, sequencer, address(new E2EVerifier()), keccak256("f"), keccak256("c"), CHALLENGE_WINDOW, CHALLENGE_BOND)
                    )
                )
            )
        );

        // 5. Ledger (sender = sequencer, treasury = ledgerTreasury)
        ledger = Ledger(
            payable(
                _proxy(
                    address(new Ledger()),
                    abi.encodeCall(Ledger.initialize, (owner, address(dispatcher), sequencer, address(ledgerTreasury)))
                )
            )
        );

        // 6. BridgedNFTs
        nft = BridgedNFTs(
            _proxy(
                address(new BridgedNFTs()),
                abi.encodeCall(BridgedNFTs.initialize, ("Dual Network NFT", "DNFT", sequencer, owner, "ipfs://"))
            )
        );

        // ── wire the topology ──
        vm.startPrank(owner);
        vault.setFeeDispatcher(address(dispatcher));
        dispatcher.setBatchRegistry(address(registry));
        dispatcher.setLedger(address(ledger));
        dispatcher.addRecipient(payable(address(staking)), 5000); // 50% to stakers
        dispatcher.addRecipient(payable(address(fdTreasury)), 3000); // 30% to treasury (20% retained)
        registry.setFeeDispatcher(address(dispatcher));
        vm.stopPrank();
    }

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    // ── helpers ──

    function _stake(address who, uint256 amount) internal {
        vm.deal(who, amount);
        injected += amount;
        vm.prank(who);
        staking.stake{value: amount}();
    }

    function _vaultDeposit(uint256 amount) internal {
        vm.deal(partner, amount);
        injected += amount;
        vm.prank(partner);
        vault.depositDual{value: amount}(keccak256("org"));
    }

    function _commitBatchWithFee(bytes32 prev, bytes32 commitment, uint256 fee) internal returns (bytes32) {
        bytes32 root = keccak256(abi.encode("root", commitment));
        bytes memory pv = abi.encode(prev, commitment, root);
        vm.prank(sequencer);
        registry.commitBatchWithProof(prev, commitment, root, "proof", pv, "uri", fee);
        return sha256(abi.encodePacked(prev, commitment));
    }

    /// @dev Sum of all native held anywhere in the system + claimant wallets.
    function _systemNative() internal view returns (uint256) {
        return address(vault).balance + address(dispatcher).balance + address(registry).balance
            + address(ledger).balance + address(staking).balance + address(fdTreasury).balance
            + address(ledgerTreasury).balance + staker.balance + staker2.balance;
    }

    function _assertConserved() internal view {
        assertEq(_systemNative(), injected, "system native not conserved");
    }

    // ── E2E: batch-fee path ───────────────────────────────────────────────────

    function test_E2E_BatchFeePathToStakerClaim() public {
        _stake(staker, 10 ether); // staker present before fees arrive
        _vaultDeposit(100 ether); // partner funds future batch fees

        // Sequencer commits a proven batch carrying a 10-ether fee; it finalizes
        // immediately and the fee is pulled from the Vault and distributed.
        _commitBatchWithFee(bytes32(0), keccak256("b1"), 10 ether);

        // 50% to Staking, 30% to treasury, 20% retained in the dispatcher.
        assertEq(address(fdTreasury).balance, 3 ether);
        assertEq(address(dispatcher).balance, 2 ether);
        assertEq(address(vault).balance, 90 ether);
        assertGt(staking.rewardRate(), 0); // stream opened from the 5-ether share

        // After the period the lone staker can claim ~the full 5-ether share.
        skip(REWARDS_DURATION + 1);
        uint256 preview = staking.previewRewards(staker);
        assertApproxEqAbs(preview, 5 ether, 1e7);

        vm.prank(staker);
        uint256 claimed = staking.claimRewards();
        assertApproxEqAbs(claimed, 5 ether, 1e7);
        assertEq(staker.balance, claimed);

        _assertConserved();
    }

    // ── E2E: ledger-fee path ──────────────────────────────────────────────────

    function test_E2E_LedgerFeePathToStakerClaim() public {
        _stake(staker, 10 ether);

        // Owner funds the Ledger; sequencer processes a partner fee.
        vm.deal(owner, 20 ether);
        injected += 20 ether;
        vm.prank(owner);
        ledger.deposit{value: 20 ether}();

        vm.prank(sequencer);
        ledger.processSingleFee(
            ILedger.SingleFeeParams({refId: keccak256("ref1"), tokenId: 1, fee: 8 ether, timestamp: block.timestamp})
        );

        // Ledger split 50/50: 4 to its treasury, 4 pushed to the FeeDispatcher.
        assertEq(address(ledgerTreasury).balance, 4 ether);
        // Dispatcher splits its 4: 2 to Staking, 1.2 to fdTreasury, 0.8 retained.
        assertEq(address(fdTreasury).balance, 1.2 ether);
        assertEq(address(dispatcher).balance, 0.8 ether);
        assertGt(staking.rewardRate(), 0);

        skip(REWARDS_DURATION + 1);
        vm.prank(staker);
        uint256 claimed = staking.claimRewards();
        assertApproxEqAbs(claimed, 2 ether, 1e7);

        _assertConserved();
    }

    // ── E2E: mixed flows + NFT lifecycle + global conservation ────────────────

    function test_E2E_MixedFlowsConserveSystemNative() public {
        // Two stakers split rewards pro-rata.
        _stake(staker, 6 ether);
        _stake(staker2, 4 ether); // 60/40 split

        _vaultDeposit(50 ether);

        // Batch fee path.
        _commitBatchWithFee(bytes32(0), keccak256("bb1"), 10 ether); // 5 -> staking

        // Ledger fee path.
        vm.deal(owner, 10 ether);
        injected += 10 ether;
        vm.prank(owner);
        ledger.deposit{value: 10 ether}();
        vm.prank(sequencer);
        ledger.processSingleFee(
            ILedger.SingleFeeParams({refId: keccak256("r2"), tokenId: 9, fee: 4 ether, timestamp: block.timestamp})
        );

        // BridgedNFTs lifecycle in the same world (no native, but proves it
        // composes and is independently governed by the sequencer).
        vm.prank(sequencer);
        nft.sequencerMint(nftUser, 1);
        vm.prank(nftUser);
        nft.requestForceSovereignty(1);
        skip(nft.FORCE_EXIT_DELAY() + 1);
        vm.prank(nftUser);
        nft.executeForceSovereignty(1);
        assertTrue(nft.isUserSovereign(1));

        // Let rewards stream and both stakers exit fully.
        skip(REWARDS_DURATION + 1);
        vm.prank(staker);
        staking.exit();
        vm.prank(staker2);
        staking.exit();

        // Pro-rata: staker (60%) earned ~1.5x staker2 (40%) of total rewards.
        uint256 r1 = staker.balance - 6 ether; // claimed rewards (principal returned too)
        uint256 r2 = staker2.balance - 4 ether;
        assertApproxEqRel(r1 * 4, r2 * 6, 0.001e18); // r1/r2 ≈ 60/40

        // The whole system conserves every injected wei.
        _assertConserved();
    }
}
