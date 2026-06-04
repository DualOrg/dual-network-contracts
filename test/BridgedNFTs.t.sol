// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BridgedNFTs} from "../src/BridgedNFTs.sol";

contract BridgedNFTsTest is Test {
    BridgedNFTs nft;

    address owner = makeAddr("owner");
    address sequencer = makeAddr("sequencer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    string constant NAME = "Dual Network NFT";
    string constant SYMBOL = "DNFT";
    string constant BASE_URI = "ipfs://base/";

    event SovereigntyReleased(uint256 indexed tokenId, address indexed owner);
    event SovereigntyForceClaimed(
        uint256 indexed tokenId,
        address indexed owner
    );
    event SovereigntyRenounced(uint256 indexed tokenId, address indexed owner);
    event ForceSovereigntyRequested(
        uint256 indexed tokenId,
        address indexed owner
    );
    event ForceSovereigntyCancelled(
        uint256 indexed tokenId,
        address indexed owner
    );
    event BaseUriSet(string oldBaseUri, string newBaseUri);
    event SequencerUpdated(
        address indexed oldSequencer,
        address indexed newSequencer
    );

    function _deployNFT(
        string memory name_,
        string memory symbol_,
        address seq,
        address _owner,
        string memory baseUri
    ) internal returns (BridgedNFTs) {
        BridgedNFTs impl = new BridgedNFTs();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                BridgedNFTs.initialize,
                (name_, symbol_, seq, _owner, baseUri)
            )
        );
        return BridgedNFTs(address(proxy));
    }

    function setUp() public {
        nft = _deployNFT(NAME, SYMBOL, sequencer, owner, BASE_URI);
    }

    // ── initialize ───────────────────────────────────────────────────────────

    function test_NameAndSymbol_AreCanonical() public view {
        assertEq(nft.name(), NAME);
        assertEq(nft.symbol(), SYMBOL);
    }

    function test_Initialize_IgnoresCustomNameAndSymbol() public {
        BridgedNFTs custom = _deployNFT("Ignored Name", "IGN", sequencer, owner, BASE_URI);
        assertEq(custom.name(), NAME);
        assertEq(custom.symbol(), SYMBOL);
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(nft.owner(), owner);
    }

    function test_Initialize_SetsSequencer() public view {
        assertEq(nft.sequencer(), sequencer);
    }

    function test_Initialize_RevertsOnZeroSequencer() public {
        BridgedNFTs impl = new BridgedNFTs();
        vm.expectRevert(BridgedNFTs.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                BridgedNFTs.initialize,
                (NAME, SYMBOL, address(0), owner, BASE_URI)
            )
        );
    }

    function test_Initialize_RevertsOnZeroOwner() public {
        BridgedNFTs impl = new BridgedNFTs();
        vm.expectRevert(BridgedNFTs.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                BridgedNFTs.initialize,
                (NAME, SYMBOL, sequencer, address(0), BASE_URI)
            )
        );
    }

    // ── sequencerMint ─────────────────────────────────────────────────────────

    function test_SequencerMint_MintsToken() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.balanceOf(alice), 1);
    }

    function test_SequencerMint_RevertsFromNonSequencer() public {
        vm.expectRevert(BridgedNFTs.TransferRestricted.selector);
        vm.prank(alice);
        nft.sequencerMint(alice, 1);
    }

    function test_SequencerMint_RevertsWhenPaused() public {
        vm.prank(owner);
        nft.pause();

        vm.expectRevert();
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
    }

    // ── sequencerTransfer ─────────────────────────────────────────────────────

    function test_SequencerTransfer_TransfersToken() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.prank(sequencer);
        nft.sequencerTransfer(alice, bob, 1);

        assertEq(nft.ownerOf(1), bob);
    }

    function test_SequencerTransfer_RevertsIfSovereign() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(1);

        vm.expectRevert(BridgedNFTs.TransferRestricted.selector);
        vm.prank(sequencer);
        nft.sequencerTransfer(alice, bob, 1);
    }

    function test_SequencerTransfer_RevertsIfForceSovereigntyPending() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.prank(alice);
        nft.requestForceSovereignty(1);

        vm.expectRevert(BridgedNFTs.TransferRestricted.selector);
        vm.prank(sequencer);
        nft.sequencerTransfer(alice, bob, 1);
    }

    function test_SequencerTransfer_RevertsFromNonSequencer() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.expectRevert();
        vm.prank(alice);
        nft.sequencerTransfer(alice, bob, 1);
    }

    // ── sequencerBurn ─────────────────────────────────────────────────────────

    function test_SequencerBurn_BurnsToken() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.prank(sequencer);
        nft.sequencerBurn(1);

        assertEq(nft.balanceOf(alice), 0);
    }

    function test_SequencerBurn_RevertsIfSovereign() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(1);

        vm.expectRevert(BridgedNFTs.TransferRestricted.selector);
        vm.prank(sequencer);
        nft.sequencerBurn(1);
    }

    // ── sequencerReleaseSovereignty ───────────────────────────────────────────

    function test_ReleaseSovereignty_SetsFlag() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.expectEmit(true, true, false, false);
        emit SovereigntyReleased(1, alice);
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(1);

        assertTrue(nft.isUserSovereign(1));
    }

    function test_ReleaseSovereignty_RevertsIfAlreadySovereign() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(1);

        vm.expectRevert(BridgedNFTs.AlreadySovereign.selector);
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(1);
    }

    // ── sovereign user transfers ───────────────────────────────────────────────

    function test_SovereignUser_CanTransferDirectly() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(1);

        // Alice can now transfer using standard ERC721 transfer
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        assertEq(nft.ownerOf(1), bob);
    }

    function test_NonSovereignUser_CannotTransferDirectly() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.expectRevert(BridgedNFTs.TransferRestricted.selector);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
    }

    // ── requestForceSovereignty ────────────────────────────────────────────────

    function test_RequestForceSovereignty_RecordsRequest() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.expectEmit(true, true, false, false);
        emit ForceSovereigntyRequested(1, alice);
        vm.prank(alice);
        nft.requestForceSovereignty(1);

        assertGt(nft.forceSovereigntyRequestTime(1), 0);
        assertEq(nft.forceSovereigntyRequester(1), alice);
    }

    function test_RequestForceSovereignty_RevertsIfNotOwner() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.expectRevert(BridgedNFTs.NotOwner.selector);
        vm.prank(bob);
        nft.requestForceSovereignty(1);
    }

    function test_RequestForceSovereignty_RevertsIfAlreadySovereign() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(1);

        vm.expectRevert(BridgedNFTs.AlreadySovereign.selector);
        vm.prank(alice);
        nft.requestForceSovereignty(1);
    }

    function test_RequestForceSovereignty_RevertsIfAlreadyRequested() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(alice);
        nft.requestForceSovereignty(1);

        vm.expectRevert(BridgedNFTs.AlreadyRequested.selector);
        vm.prank(alice);
        nft.requestForceSovereignty(1);
    }

    // ── executeForceSovereignty ────────────────────────────────────────────────

    function test_ExecuteForceSovereignty_AfterDelay() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(alice);
        nft.requestForceSovereignty(1);

        vm.warp(block.timestamp + nft.FORCE_EXIT_DELAY() + 1);

        vm.expectEmit(true, true, false, false);
        emit SovereigntyForceClaimed(1, alice);
        vm.prank(alice);
        nft.executeForceSovereignty(1);

        assertTrue(nft.isUserSovereign(1));
    }

    function test_ExecuteForceSovereignty_RevertsBeforeDelay() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(alice);
        nft.requestForceSovereignty(1);

        vm.expectRevert(BridgedNFTs.TooEarly.selector);
        vm.prank(alice);
        nft.executeForceSovereignty(1);
    }

    function test_ExecuteForceSovereignty_RevertsWithNoActiveRequest() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        // forceSovereigntyRequester[1] == address(0) != alice → NotRequester (checked first)
        vm.expectRevert(BridgedNFTs.NotRequester.selector);
        vm.prank(alice);
        nft.executeForceSovereignty(1);
    }

    function test_ExecuteForceSovereignty_RevertsIfNotOwner() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(alice);
        nft.requestForceSovereignty(1);

        vm.warp(block.timestamp + nft.FORCE_EXIT_DELAY() + 1);

        // Bob doesn't own token 1
        vm.expectRevert(BridgedNFTs.NotOwner.selector);
        vm.prank(bob);
        nft.executeForceSovereignty(1);
    }

    // ── cancelForceSovereignty ─────────────────────────────────────────────────

    function test_CancelForceSovereignty_ClearsRequest() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(alice);
        nft.requestForceSovereignty(1);

        vm.expectEmit(true, true, false, false);
        emit ForceSovereigntyCancelled(1, alice);
        vm.prank(alice);
        nft.cancelForceSovereignty(1);

        assertEq(nft.forceSovereigntyRequestTime(1), 0);
        assertEq(nft.forceSovereigntyRequester(1), address(0));
    }

    function test_CancelForceSovereignty_RevertsWithNoRequest() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.expectRevert(BridgedNFTs.NoActiveRequest.selector);
        vm.prank(alice);
        nft.cancelForceSovereignty(1);
    }

    // ── userRenounceSovereignty ────────────────────────────────────────────────

    function test_UserRenounceSovereignty_ClearsFlag() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(1);

        vm.expectEmit(true, true, false, false);
        emit SovereigntyRenounced(1, alice);
        vm.prank(alice);
        nft.userRenounceSovereignty(1);

        assertFalse(nft.isUserSovereign(1));
    }

    function test_UserRenounceSovereignty_RevertsIfNotSovereign() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);

        vm.expectRevert(BridgedNFTs.NotSovereign.selector);
        vm.prank(alice);
        nft.userRenounceSovereignty(1);
    }

    // ── setBaseUri ────────────────────────────────────────────────────────────

    function test_SetBaseUri_UpdatesUri() public {
        string memory newUri = "ipfs://new/";
        vm.expectEmit(false, false, false, true);
        emit BaseUriSet(BASE_URI, newUri);
        vm.prank(owner);
        nft.setBaseUri(newUri);
    }

    function test_SetBaseUri_RevertsFromNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        nft.setBaseUri("ipfs://hack/");
    }

    // ── setSequencer ──────────────────────────────────────────────────────────

    function test_SetSequencer_UpdatesSequencer() public {
        address newSeq = makeAddr("newSeq");
        vm.expectEmit(true, true, false, false);
        emit SequencerUpdated(sequencer, newSeq);
        vm.prank(owner);
        nft.setSequencer(newSeq);

        assertEq(nft.sequencer(), newSeq);
    }

    function test_SetSequencer_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BridgedNFTs.ZeroAddress.selector);
        nft.setSequencer(address(0));
    }

    function test_SetSequencer_RevertsOnSameValue() public {
        vm.prank(owner);
        vm.expectRevert(BridgedNFTs.UnchangedValue.selector);
        nft.setSequencer(sequencer);
    }

    function test_SetSequencer_RevertsFromNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        nft.setSequencer(makeAddr("x"));
    }

    // ── isUserSovereignBatch ──────────────────────────────────────────────────

    function test_IsUserSovereignBatch() public {
        vm.prank(sequencer);
        nft.sequencerMint(alice, 1);
        vm.prank(sequencer);
        nft.sequencerMint(alice, 2);
        vm.prank(sequencer);
        nft.sequencerReleaseSovereignty(1); // token 1 is sovereign

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        bool[] memory results = nft.isUserSovereignBatch(ids);

        assertTrue(results[0]);
        assertFalse(results[1]);
    }

    // ── pause / unpause ───────────────────────────────────────────────────────

    function test_Pause_OnlyOwner() public {
        vm.prank(owner);
        nft.pause();
        assertTrue(nft.paused());
    }

    function test_Pause_RevertsFromNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        nft.pause();
    }

    function test_Unpause_Succeeds() public {
        vm.prank(owner);
        nft.pause();
        vm.prank(owner);
        nft.unpause();
        assertFalse(nft.paused());
    }
}
