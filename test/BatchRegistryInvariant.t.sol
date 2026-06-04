// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";
import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";
import {IFeeDispatcher} from "../src/interfaces/IFeeDispatcher.sol";

contract MockVerifier is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure override {}
}

contract MockDispatcher is IFeeDispatcher {
    function dispatchFee(bytes32, uint256) external pure override returns (bool) {
        return true;
    }

    function dispatchLedgerFee(bytes32, uint256) external payable override returns (bool) {
        return true;
    }
}

contract BatchRegistryHandler is Test {
    BatchRegistry public immutable reg;
    address[3] public users;

    struct Meta {
        bytes32 prev;
        bytes32 commitment;
        bytes32 root;
    }

    bytes32 public lastHash;
    bytes32[] public hashes;
    mapping(bytes32 => Meta) public metas;
    uint256 internal nonce;

    uint256 public ghost_directSends;
    uint256 public ghost_emergencyWithdrawn;

    constructor(BatchRegistry _reg, address[3] memory _users) {
        reg = _reg;
        users = _users;
    }

    receive() external payable {}

    function hashCount() external view returns (uint256) {
        return hashes.length;
    }

    function hashAt(uint256 i) external view returns (bytes32) {
        return hashes[i];
    }

    // Handler is the sequencer.
    function commit(uint256 feeSeed) public {
        bytes32 prev = lastHash;
        bytes32 commitment = keccak256(abi.encode("c", nonce));
        bytes32 root = keccak256(abi.encode("r", nonce));
        nonce++;
        uint256 fee = bound(feeSeed, 0, 10 ether);
        try reg.commitBatch(prev, commitment, root, "uri", fee) {
            bytes32 bh = sha256(abi.encodePacked(prev, commitment));
            lastHash = bh;
            hashes.push(bh);
            metas[bh] = Meta(prev, commitment, root);
        } catch {}
    }

    function challenge(uint256 hashSeed, uint256 userSeed) public {
        if (hashes.length == 0) return;
        bytes32 bh = hashes[bound(hashSeed, 0, hashes.length - 1)];
        address u = users[bound(userSeed, 0, 2)];
        uint256 bond = reg.challengeBond();
        vm.deal(u, bond);
        vm.prank(u);
        try reg.challengeBatch{value: bond}(bh) {} catch {}
    }

    function resolve(uint256 hashSeed, bool fraud) public {
        if (hashes.length == 0) return;
        bytes32 bh = hashes[bound(hashSeed, 0, hashes.length - 1)];
        Meta memory m = metas[bh];
        bytes32 provedRoot = fraud ? keccak256("wrong") : m.root;
        bytes memory pv = abi.encode(m.prev, m.commitment, provedRoot);
        try reg.resolveChallenge(bh, "proof", pv) {} catch {}
    }

    function finalize(uint256 hashSeed) public {
        if (hashes.length == 0) return;
        bytes32 bh = hashes[bound(hashSeed, 0, hashes.length - 1)];
        try reg.finalizeBatch(bh) {} catch {}
    }

    function claim(uint256 userSeed) public {
        address u = users[bound(userSeed, 0, 2)];
        vm.prank(u);
        try reg.claimWithdrawal() {} catch {}
    }

    function claimSequencer() public {
        vm.prank(address(this)); // handler is the sequencer
        try reg.claimWithdrawal() {} catch {}
    }

    function directSend(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(reg).call{value: amount}("");
        if (ok) ghost_directSends += amount;
    }

    function emergencyWithdraw(uint256 amount) public {
        uint256 surplus = reg.withdrawableSurplus();
        if (surplus == 0) return;
        amount = bound(amount, 1, surplus);
        try reg.emergencyWithdraw(payable(users[0]), amount) {
            ghost_emergencyWithdrawn += amount;
        } catch {}
    }

    function warp(uint256 secs) public {
        secs = bound(secs, 1, 2 days);
        vm.warp(block.timestamp + secs);
    }
}

contract BatchRegistryInvariantTest is Test {
    BatchRegistry internal reg;
    BatchRegistryHandler internal handler;
    address[3] internal users;

    uint256 internal constant CHALLENGE_WINDOW = 30 days;
    uint256 internal constant CHALLENGE_BOND = 100_000 ether;

    function setUp() public {
        vm.warp(1_000_000);
        users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2")];

        MockVerifier verifier = new MockVerifier();
        MockDispatcher dispatcher = new MockDispatcher();

        BatchRegistry impl = new BatchRegistry();
        handler = BatchRegistryHandler(payable(computeCreateAddress(address(this), vm.getNonce(address(this)) + 1)));
        reg = BatchRegistry(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            BatchRegistry.initialize,
                            (
                                address(handler), // owner
                                address(handler), // sequencer
                                address(verifier),
                                keccak256("fraud"),
                                keccak256("ckpt"),
                                CHALLENGE_WINDOW,
                                CHALLENGE_BOND
                            )
                        )
                    )
                )
            )
        );
        BatchRegistryHandler deployed = new BatchRegistryHandler(reg, users);
        require(address(deployed) == address(handler), "handler addr mismatch");

        // Disable halt-on-fraud so fraud resolutions don't pause the handler, and
        // wire a benign fee dispatcher.
        vm.startPrank(address(handler));
        reg.setHaltOnFraud(false);
        reg.setFeeDispatcher(address(dispatcher));
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// @notice Native conservation: contract balance equals escrowed bonds +
    ///         pending withdrawals + direct surplus - emergency withdrawals.
    function invariant_conservation() public view {
        uint256 reserved = reg.totalActiveBonds() + reg.totalPendingWithdrawals();
        assertEq(
            address(reg).balance,
            reserved + handler.ghost_directSends() - handler.ghost_emergencyWithdrawn(),
            "native not conserved"
        );
    }

    /// @notice Solvency: escrowed bonds + pending withdrawals are always fully
    ///         backed by the contract balance.
    function invariant_solvency() public view {
        assertGe(address(reg).balance, reg.totalActiveBonds() + reg.totalPendingWithdrawals(), "under-collateralized");
    }

    /// @notice The pending-withdrawals total equals the sum of per-account
    ///         pending balances (challengers + sequencer).
    function invariant_pendingTotalsReconcile() public view {
        uint256 sum = reg.pendingWithdrawals(users[0]) + reg.pendingWithdrawals(users[1])
            + reg.pendingWithdrawals(users[2]) + reg.pendingWithdrawals(address(handler));
        assertEq(reg.totalPendingWithdrawals(), sum, "pending totals drift");
    }
}
