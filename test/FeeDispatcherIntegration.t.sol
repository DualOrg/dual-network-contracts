// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";
import {Vault} from "../src/Vault.sol";
import {FeeSource} from "../src/libraries/FeeSource.sol";

contract Sink {
    receive() external payable {}
}

contract RejectingRecipient {
    receive() external payable {
        revert("reject");
    }
}

/// @dev A recipient that is ALSO the authorized ledger, re-entering on payout.
contract ReentrantLedgerRecipient {
    FeeDispatcher public dispatcher;
    bool public attempted;
    bool public blocked;

    function setDispatcher(FeeDispatcher _d) external {
        dispatcher = _d;
    }

    function fire(bytes32 refId, uint256 fee) external {
        dispatcher.dispatchLedgerFee{value: fee}(refId, fee);
    }

    receive() external payable {
        if (!attempted && address(dispatcher) != address(0)) {
            attempted = true;
            try dispatcher.dispatchLedgerFee{value: 1}(keccak256("re"), 1) {
                blocked = false;
            } catch {
                blocked = true;
            }
        }
    }
}

contract FeeDispatcherIntegrationTest is Test {
    FeeDispatcher internal dispatcher;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal batchRegistry = makeAddr("batchRegistry");
    address internal ledger = makeAddr("ledger");

    function setUp() public {
        Vault vimpl = new Vault();
        vault = Vault(payable(address(new ERC1967Proxy(address(vimpl), abi.encodeCall(Vault.initialize, (owner))))));

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

        // Authorize the dispatcher to pull batch fees from the vault.
        vm.prank(owner);
        vault.setFeeDispatcher(address(dispatcher));
    }

    function _fundVault(uint256 amount) internal {
        vm.deal(address(this), amount);
        vault.depositDual{value: amount}(keccak256("org"));
    }

    // ── integration: batch fee pulled from Vault and distributed ──────────────

    function test_Integration_BatchFeePullsFromVaultAndDistributes() public {
        Sink r = new Sink();
        vm.prank(owner);
        dispatcher.addRecipient(payable(address(r)), 6000); // 60%

        _fundVault(10 ether);

        vm.prank(batchRegistry);
        bool ok = dispatcher.dispatchFee(keccak256("batch1"), 5 ether);
        assertTrue(ok);

        // 60% to recipient; 40% retained in the dispatcher; vault debited the fee.
        assertEq(address(r).balance, 3 ether);
        assertEq(dispatcher.totalFeesDistributed(), 3 ether);
        assertEq(dispatcher.totalFeesRetained(), 2 ether);
        assertEq(address(dispatcher).balance, 2 ether);
        assertEq(address(vault).balance, 5 ether);
        assertEq(vault.totalWithdrawnForFees(), 5 ether);
    }

    /// @notice If the Vault withdrawal fails, dispatchFee returns false and makes
    ///         no distribution (graceful degradation).
    function test_Integration_BatchFeeFailsGracefullyWhenVaultEmpty() public {
        Sink r = new Sink();
        vm.prank(owner);
        dispatcher.addRecipient(payable(address(r)), 10_000);

        // Vault has no funds → withdrawForFeeDistribution reverts → caught.
        vm.prank(batchRegistry);
        bool ok = dispatcher.dispatchFee(keccak256("batch2"), 1 ether);
        assertFalse(ok);
        assertEq(dispatcher.totalFeesDispatched(), 0);
    }

    /// @notice A reverting recipient does not block the batch: its share is
    ///         retained, the dispatch still succeeds.
    function test_Adversarial_BadRecipientShareIsRetained() public {
        RejectingRecipient bad = new RejectingRecipient();
        Sink good = new Sink();
        vm.startPrank(owner);
        dispatcher.addRecipient(payable(address(bad)), 4000);
        dispatcher.addRecipient(payable(address(good)), 6000);
        vm.stopPrank();

        _fundVault(10 ether);
        vm.prank(batchRegistry);
        dispatcher.dispatchFee(keccak256("batch3"), 10 ether);

        assertEq(address(good).balance, 6 ether);
        assertEq(dispatcher.totalFeesDistributed(), 6 ether);
        assertEq(dispatcher.totalFeesRetained(), 4 ether); // bad recipient's share
        assertEq(address(dispatcher).balance, 4 ether);
    }

    // ── adversarial: reentrancy via recipient payout ──────────────────────────

    function test_Adversarial_ReentrantRecipientIsBlocked() public {
        ReentrantLedgerRecipient attacker = new ReentrantLedgerRecipient();
        attacker.setDispatcher(dispatcher);

        // Make the attacker the authorized ledger AND a fee recipient.
        vm.startPrank(owner);
        dispatcher.setLedger(address(attacker));
        dispatcher.addRecipient(payable(address(attacker)), 5000);
        vm.stopPrank();

        vm.deal(address(attacker), 4 ether);
        attacker.fire(keccak256("led1"), 4 ether);

        assertTrue(attacker.attempted(), "reentry path not exercised");
        assertTrue(attacker.blocked(), "reentrancy was NOT blocked");
        // Exactly one dispatch recorded — the re-entry made no second dispatch.
        assertEq(dispatcher.totalFeesDispatched(), 4 ether);
    }
}
