// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ledger} from "../src/Ledger.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";
import {Vault} from "../src/Vault.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";

contract Sink {
    receive() external payable {}
}

contract RejectingRecipient {
    receive() external payable {
        revert("reject");
    }
}

/// @dev Holds SENDER_ROLE and is the treasury. When it receives the treasury leg
///      mid-dispatch, it re-enters processSingleFee — which must be blocked.
contract ReentrantSender {
    Ledger public ledger;
    bool public attempted;
    bool public reentryBlocked;

    function setLedger(Ledger _l) external {
        ledger = _l;
    }

    function fire(bytes32 refId, uint256 fee) external {
        ledger.processSingleFee(ILedger.SingleFeeParams({refId: refId, tokenId: 1, fee: fee, timestamp: block.timestamp}));
    }

    receive() external payable {
        if (!attempted && address(ledger) != address(0)) {
            attempted = true;
            try ledger.processSingleFee(
                ILedger.SingleFeeParams({refId: keccak256("reenter"), tokenId: 2, fee: 1, timestamp: block.timestamp})
            ) {
                reentryBlocked = false;
            } catch {
                reentryBlocked = true;
            }
        }
    }
}

contract LedgerIntegrationTest is Test {
    Ledger internal ledger;
    FeeDispatcher internal dispatcher;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal sender = makeAddr("sender");

    function setUp() public {
        vm.warp(1_000_000);

        Vault vimpl = new Vault();
        vault = Vault(payable(address(new ERC1967Proxy(address(vimpl), abi.encodeCall(Vault.initialize, (owner))))));

        FeeDispatcher fimpl = new FeeDispatcher();
        dispatcher = FeeDispatcher(
            payable(
                address(
                    new ERC1967Proxy(
                        address(fimpl),
                        // ledger placeholder; rewired via setLedger after Ledger exists.
                        abi.encodeCall(FeeDispatcher.initialize, (owner, address(vault), makeAddr("batch"), owner))
                    )
                )
            )
        );

        Sink treasury = new Sink();
        Ledger limpl = new Ledger();
        ledger = Ledger(
            payable(
                address(
                    new ERC1967Proxy(
                        address(limpl),
                        abi.encodeCall(Ledger.initialize, (admin, address(dispatcher), sender, address(treasury)))
                    )
                )
            )
        );

        // Authorize Ledger to push ledger fees into the dispatcher.
        vm.prank(owner);
        dispatcher.setLedger(address(ledger));
    }

    function _deposit(uint256 amount) internal {
        vm.deal(admin, amount);
        vm.prank(admin);
        ledger.deposit{value: amount}();
    }

    function _single(bytes32 refId, uint256 fee) internal view returns (ILedger.SingleFeeParams memory) {
        return ILedger.SingleFeeParams({refId: refId, tokenId: 1, fee: fee, timestamp: block.timestamp});
    }

    // ── integration: Ledger fee flows through the real FeeDispatcher ───────────

    function test_Integration_LedgerFeeFlowsThroughDispatcher() public {
        Sink recipient = new Sink();
        vm.prank(owner);
        dispatcher.addRecipient(payable(address(recipient)), 10_000); // 100% of dispatcher share

        _deposit(10 ether);

        address treasury = ledger.treasury();
        uint256 treasuryBefore = treasury.balance;

        vm.prank(sender);
        ledger.processSingleFee(_single(keccak256("r1"), 4 ether)); // 50/50 split

        // Dispatcher share (2) reached the recipient; treasury share (2) reached treasury.
        assertEq(address(recipient).balance, 2 ether);
        assertEq(treasury.balance - treasuryBefore, 2 ether);
        assertEq(ledger.dispatchedFees(), 2 ether);
        assertEq(ledger.treasuryFees(), 2 ether);
        assertEq(address(ledger).balance, 6 ether);
    }

    /// @notice A reverting downstream recipient does not block the Ledger: the
    ///         dispatcher tolerates the failed send, so processSingleFee succeeds.
    function test_Integration_BadRecipientDoesNotBlockLedger() public {
        RejectingRecipient bad = new RejectingRecipient();
        vm.prank(owner);
        dispatcher.addRecipient(payable(address(bad)), 10_000);

        _deposit(10 ether);

        vm.prank(sender);
        ledger.processSingleFee(_single(keccak256("r2"), 4 ether));

        // Ledger still recorded the dispatch; the undeliverable share stayed in the
        // dispatcher (not lost), and the treasury leg paid out.
        assertEq(ledger.dispatchedFees(), 2 ether);
        assertEq(ledger.treasuryFees(), 2 ether);
        assertEq(address(dispatcher).balance, 2 ether);
    }

    // ── adversarial: reentrancy via the treasury callback ─────────────────────

    function test_Adversarial_ReentrantTreasuryIsBlocked() public {
        ReentrantSender attacker = new ReentrantSender();
        attacker.setLedger(ledger);

        // Make the attacker both the treasury (receives the treasury leg) and a
        // SENDER so its re-entry would otherwise be authorized.
        vm.startPrank(admin);
        ledger.setTreasury(address(attacker));
        ledger.grantSenderRole(address(attacker));
        vm.stopPrank();

        _deposit(10 ether);

        // Attacker triggers a fee; during the treasury payout it re-enters
        // processSingleFee, which nonReentrant must block.
        attacker.fire(keccak256("r3"), 4 ether);

        assertTrue(attacker.attempted(), "reentry path not exercised");
        assertTrue(attacker.reentryBlocked(), "reentrancy was NOT blocked");
        // Exactly ONE fee processed — no double accounting from the re-entry.
        assertEq(ledger.totalRecords(), 1);
        assertEq(ledger.totalFees(), 4 ether);
        assertEq(address(ledger).balance, 6 ether);
    }
}
