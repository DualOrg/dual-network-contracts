// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Staking} from "../src/StakingFinal.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";
import {Vault} from "../src/Vault.sol";

/// @dev Recipient that rejects native — exercises FeeDispatcher's
///      "failed send is tolerated" path without blocking other recipients.
contract RejectingRecipient {
    receive() external payable {
        revert("reject");
    }
}

/// @dev Staker contract that re-enters Staking on receiving its unstaked native.
///      Used to prove nonReentrant blocks reentrancy through the native send.
contract Reenterer {
    Staking public immutable staking;
    bool public attempted;
    bool public reentryReverted;

    constructor(Staking _staking) {
        staking = _staking;
    }

    function doStake() external payable {
        staking.stake{value: msg.value}();
    }

    function doUnstake(uint256 amount) external {
        staking.unstake(amount);
    }

    receive() external payable {
        if (!attempted) {
            attempted = true;
            // Re-enter during the unstake native transfer; must be blocked.
            try staking.unstake(1) {
                reentryReverted = false;
            } catch {
                reentryReverted = true;
            }
        }
    }
}

contract StakingIntegrationTest is Test {
    Staking internal staking;
    FeeDispatcher internal dispatcher;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal ledger = makeAddr("ledger");
    address internal batchRegistry = makeAddr("batchRegistry");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant REWARDS_DURATION = 7 days;

    function setUp() public {
        // Vault
        Vault vimpl = new Vault();
        vault = Vault(payable(address(new ERC1967Proxy(address(vimpl), abi.encodeCall(Vault.initialize, (owner))))));

        // FeeDispatcher
        FeeDispatcher fimpl = new FeeDispatcher();
        dispatcher = FeeDispatcher(
            payable(
                address(
                    new ERC1967Proxy(
                        address(fimpl),
                        abi.encodeCall(FeeDispatcher.initialize, (owner, address(vault), batchRegistry, ledger))
                    )
                )
            )
        );

        // Staking, wired to the real dispatcher as its fee source.
        Staking simpl = new Staking();
        staking = Staking(
            payable(
                address(
                    new ERC1967Proxy(
                        address(simpl),
                        abi.encodeCall(Staking.initialize, (owner, address(dispatcher), REWARDS_DURATION))
                    )
                )
            )
        );
    }

    function _stake(address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        staking.stake{value: amount}();
    }

    // ── integration: real FeeDispatcher → Staking stream ──────────────────────

    function test_Integration_LedgerFeeStartsStream() public {
        _stake(alice, 10 ether);

        // 50% of fees route to Staking.
        vm.prank(owner);
        dispatcher.addRecipient(payable(address(staking)), 5000);

        uint256 fee = 4 ether;
        vm.deal(ledger, fee);
        vm.prank(ledger);
        dispatcher.dispatchLedgerFee{value: fee}(keccak256("src1"), fee);

        // Staking received its 50% share and opened a stream.
        assertEq(address(staking).balance, 10 ether + 2 ether);
        assertGt(staking.rewardRate(), 0);
        assertGt(staking.periodFinish(), block.timestamp);

        // After the full period alice can claim ~the streamed share.
        vm.warp(block.timestamp + REWARDS_DURATION + 1);
        uint256 preview = staking.previewRewards(alice);
        assertApproxEqAbs(preview, 2 ether, 1e6); // rounding dust only

        vm.prank(alice);
        uint256 claimed = staking.claimRewards();
        assertApproxEqAbs(claimed, 2 ether, 1e6);
    }

    /// @notice A reverting co-recipient does NOT block Staking's fee delivery, and
    ///         the dispatcher completes the batch (FeeDistributionFailed tolerated).
    function test_Integration_BadRecipientDoesNotBlockStaking() public {
        _stake(alice, 10 ether);

        RejectingRecipient bad = new RejectingRecipient();
        vm.startPrank(owner);
        dispatcher.addRecipient(payable(address(bad)), 3000); // 30% → reverts
        dispatcher.addRecipient(payable(address(staking)), 5000); // 50% → Staking
        vm.stopPrank();

        uint256 fee = 10 ether;
        vm.deal(ledger, fee);
        vm.prank(ledger);
        bool ok = dispatcher.dispatchLedgerFee{value: fee}(keccak256("src2"), fee);

        assertTrue(ok, "dispatch should succeed despite bad recipient");
        // Staking still got its 50%; the bad recipient's 30% stayed in dispatcher.
        assertEq(address(staking).balance, 10 ether + 5 ether);
        assertGt(staking.rewardRate(), 0);
    }

    // ── adversarial: reentrancy via native send ──────────────────────────────

    function test_Adversarial_ReentrancyOnUnstakeIsBlocked() public {
        Reenterer attacker = new Reenterer(staking);
        vm.deal(address(this), 5 ether); // fund the staking call exactly once
        attacker.doStake{value: 5 ether}();
        assertEq(address(attacker).balance, 0);

        // Unstake triggers the native send → attacker re-enters during receive().
        // nonReentrant blocks the inner call; the attacker swallows that revert, so
        // the legitimate unstake completes — but crucially there is NO double
        // withdrawal: principal is returned exactly once.
        attacker.doUnstake(5 ether);

        assertTrue(attacker.attempted(), "reentry path not exercised");
        assertTrue(attacker.reentryReverted(), "reentrancy was NOT blocked");
        assertEq(staking.balanceOf(address(attacker)), 0);
        assertEq(address(attacker).balance, 5 ether, "double withdrawal!");
        assertEq(staking.totalSupply(), 0);
    }

    // ── adversarial: zero-supply churn keeps the contract solvent ─────────────

    function test_Adversarial_ZeroSupplyChurnPreservesSolvency() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(address(staking)), 10000); // 100% → Staking

        // 1) alice stakes, fees stream, alice fully exits (parks remainder).
        _stake(alice, 1 ether);
        _ledgerFee(2 ether, "c1");
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.exit();
        assertEq(staking.totalSupply(), 0);

        // 2) Fees arrive while supply == 0 → parked.
        _ledgerFee(1 ether, "c2");
        assertGt(staking.pendingRewards(), 0);

        // 3) bob stakes → parked rewards fold into a fresh stream.
        _stake(bob, 3 ether);
        assertGt(staking.rewardRate(), 0);
        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        // 4) bob exits; everyone is whole and the contract stays solvent.
        vm.prank(bob);
        staking.exit();

        uint256 reserved = staking.totalSupply() + staking.committedRewards() + staking.pendingRewards();
        assertGe(address(staking).balance, reserved, "insolvent after churn");
        assertEq(staking.totalSupply(), 0);
    }

    function _ledgerFee(uint256 fee, bytes32 tag) internal {
        vm.deal(ledger, fee);
        vm.prank(ledger);
        dispatcher.dispatchLedgerFee{value: fee}(tag, fee);
    }
}
