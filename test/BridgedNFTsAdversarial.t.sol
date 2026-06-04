// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BridgedNFTs} from "../src/BridgedNFTs.sol";

contract BridgedNFTsAdversarialTest is Test {
    BridgedNFTs internal nft;
    address internal owner = makeAddr("owner");
    address internal sequencer = makeAddr("sequencer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant TOKEN = 1;

    function setUp() public {
        vm.warp(1_000_000);
        BridgedNFTs impl = new BridgedNFTs();
        nft = BridgedNFTs(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BridgedNFTs.initialize, ("Dual Network NFT", "DNFT", sequencer, owner, "ipfs://"))
                )
            )
        );
        vm.prank(sequencer);
        nft.sequencerMint(alice, TOKEN);
    }

    // ── adversarial: custodial transfer restriction ───────────────────────────

    function test_Adversarial_UserCannotTransferCustodialToken() public {
        // alice holds a non-sovereign (custodial) token; she cannot move it.
        vm.prank(alice);
        vm.expectRevert(BridgedNFTs.TransferRestricted.selector);
        nft.transferFrom(alice, bob, TOKEN);
    }

    function test_Adversarial_SequencerCannotMoveSovereignToken() public {
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(TOKEN);

        // Once sovereign, the sequencer can no longer seize/move the token.
        vm.prank(sequencer);
        vm.expectRevert(BridgedNFTs.TransferRestricted.selector);
        nft.sequencerTransfer(alice, bob, TOKEN);

        vm.prank(sequencer);
        vm.expectRevert(BridgedNFTs.TransferRestricted.selector);
        nft.sequencerBurn(TOKEN);
    }

    /// @notice A pending force-sovereignty request freezes the sequencer out of the
    ///         token, preventing it from front-running the user's escape.
    function test_Adversarial_PendingRequestBlocksSequencerTransfer() public {
        vm.prank(alice);
        nft.requestForceSovereignty(TOKEN);

        vm.prank(sequencer);
        vm.expectRevert(BridgedNFTs.TransferRestricted.selector);
        nft.sequencerTransfer(alice, bob, TOKEN);
    }

    // ── escape hatch: force-exit full lifecycle ───────────────────────────────

    function test_ForceExit_LifecycleGrantsSelfCustody() public {
        vm.prank(alice);
        nft.requestForceSovereignty(TOKEN);

        // Too early to execute.
        vm.prank(alice);
        vm.expectRevert(BridgedNFTs.TooEarly.selector);
        nft.executeForceSovereignty(TOKEN);

        vm.warp(block.timestamp + nft.FORCE_EXIT_DELAY() + 1);

        vm.prank(alice);
        nft.executeForceSovereignty(TOKEN);
        assertTrue(nft.isUserSovereign(TOKEN));

        // Now alice has self-custody and can transfer freely.
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN);
        assertEq(nft.ownerOf(TOKEN), bob);
    }

    /// @notice The escape hatch works even while the contract is PAUSED — pausing
    ///         cannot trap a user's in-flight force exit.
    function test_ForceExit_WorksWhilePaused() public {
        vm.prank(alice);
        nft.requestForceSovereignty(TOKEN);
        vm.warp(block.timestamp + nft.FORCE_EXIT_DELAY() + 1);

        vm.prank(owner);
        nft.pause();

        vm.prank(alice);
        nft.executeForceSovereignty(TOKEN); // not gated by whenNotPaused
        assertTrue(nft.isUserSovereign(TOKEN));
    }

    function test_Adversarial_OnlyRequesterCanExecuteOrCancel() public {
        vm.prank(alice);
        nft.requestForceSovereignty(TOKEN);
        vm.warp(block.timestamp + nft.FORCE_EXIT_DELAY() + 1);

        // bob is not the owner/requester.
        vm.prank(bob);
        vm.expectRevert(BridgedNFTs.NotOwner.selector);
        nft.executeForceSovereignty(TOKEN);

        vm.prank(bob);
        vm.expectRevert(BridgedNFTs.NotOwner.selector);
        nft.cancelForceSovereignty(TOKEN);
    }

    function test_Adversarial_ReleaseClearsPendingRequest() public {
        vm.prank(alice);
        nft.requestForceSovereignty(TOKEN);
        assertGt(nft.forceSovereigntyRequestTime(TOKEN), 0);

        // Sequencer grants sovereignty directly — must clear the stale request.
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(TOKEN);
        assertTrue(nft.isUserSovereign(TOKEN));
        assertEq(nft.forceSovereigntyRequestTime(TOKEN), 0);
        assertEq(nft.forceSovereigntyRequester(TOKEN), address(0));
    }

    // ── coverage: revert/edge paths ───────────────────────────────────────────

    function test_Release_RevertsOnMissingToken() public {
        vm.prank(sequencer);
        vm.expectRevert(BridgedNFTs.TokenNotFound.selector);
        nft.sequencerReleaseSovereignty(999);
    }

    function test_Renounce_RevertsForNonOwner() public {
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(TOKEN); // make sovereign

        vm.prank(bob);
        vm.expectRevert(BridgedNFTs.NotOwner.selector);
        nft.userRenounceSovereignty(TOKEN);
    }

    function test_Renounce_ReturnsTokenToCustody() public {
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(TOKEN);
        vm.prank(alice);
        nft.userRenounceSovereignty(TOKEN);
        assertFalse(nft.isUserSovereign(TOKEN));
    }

    function test_Views_TokenUriAndInterface() public {
        // _baseURI + tokenURI path and ERC721/Enumerable interface support.
        assertEq(nft.tokenURI(TOKEN), "ipfs://1");
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(nft.supportsInterface(0x780e9d63)); // ERC721Enumerable
        uint256[] memory ids = new uint256[](1);
        ids[0] = TOKEN;
        bool[] memory res = nft.isUserSovereignBatch(ids);
        assertFalse(res[0]);
    }
}
