// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../src/Vault.sol";
import {FeeSource} from "../src/libraries/FeeSource.sol";

/// @dev Malicious fee dispatcher: re-enters withdrawForFeeDistribution on payout.
contract ReentrantDispatcher {
    Vault public vault;
    bool public attempted;
    bool public blocked;

    function setVault(Vault _v) external {
        vault = _v;
    }

    function pull(uint256 amount) external {
        vault.withdrawForFeeDistribution(amount, FeeSource.LEDGER);
    }

    receive() external payable {
        if (!attempted && address(vault) != address(0)) {
            attempted = true;
            try vault.withdrawForFeeDistribution(1, FeeSource.LEDGER) {
                blocked = false;
            } catch {
                blocked = true;
            }
        }
    }
}

contract RejectEther {
    receive() external payable {
        revert("no");
    }
}

contract VaultIntegrationTest is Test {
    Vault internal vault;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        Vault impl = new Vault();
        vault = Vault(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(Vault.initialize, (owner))))));
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        vault.depositDual{value: amount}(keccak256("org"));
    }

    // ── adversarial: reentrancy via the fee-dispatcher payout ─────────────────

    function test_Adversarial_ReentrantDispatcherIsBlocked() public {
        ReentrantDispatcher attacker = new ReentrantDispatcher();
        attacker.setVault(vault);
        vm.prank(owner);
        vault.setFeeDispatcher(address(attacker));

        _fund(10 ether);
        attacker.pull(4 ether);

        assertTrue(attacker.attempted(), "reentry path not exercised");
        assertTrue(attacker.blocked(), "reentrancy was NOT blocked");
        // Only the single 4-ether withdrawal happened — no double drain.
        assertEq(vault.totalWithdrawnForFees(), 4 ether);
        assertEq(address(vault).balance, 6 ether);
        assertEq(address(attacker).balance, 4 ether);
    }

    // ── adversarial: authorization + failed transfer ──────────────────────────

    function test_Adversarial_WithdrawForFeesRejectsNonDispatcher() public {
        _fund(1 ether);
        vm.expectRevert(Vault.Unauthorized.selector);
        vm.prank(alice);
        vault.withdrawForFeeDistribution(1 ether, FeeSource.LEDGER);
    }

    function test_Adversarial_WithdrawForFeesRejectsBadSourceType() public {
        ReentrantDispatcher d = new ReentrantDispatcher(); // benign here, just a dispatcher
        vm.prank(owner);
        vault.setFeeDispatcher(address(d));
        _fund(1 ether);

        vm.expectRevert(Vault.InvalidSourceType.selector);
        vm.prank(address(d));
        vault.withdrawForFeeDistribution(1 ether, 99);
    }

    function test_Adversarial_WithdrawDualRevertsWhenRecipientRejects() public {
        RejectEther bad = new RejectEther();
        _fund(1 ether);
        vm.expectRevert(Vault.TransferFailed.selector);
        vm.prank(owner);
        vault.withdrawDual(address(bad), 1 ether);
    }

    // ── integration: deposit → fee withdrawal accounting ──────────────────────

    function test_Integration_FeeWithdrawalAccounting() public {
        ReentrantDispatcher d = new ReentrantDispatcher();
        // Don't trigger reentry on this path: leave vault unset on the attacker.
        vm.prank(owner);
        vault.setFeeDispatcher(address(d));

        _fund(10 ether);

        vm.prank(address(d));
        bool ok = vault.withdrawForFeeDistribution(3 ether, FeeSource.BATCH);
        assertTrue(ok);
        assertEq(vault.totalWithdrawnForFees(), 3 ether);
        assertEq(address(vault).balance, 7 ether);
        assertEq(address(d).balance, 3 ether);
    }
}
