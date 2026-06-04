// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BridgedNFTs} from "../src/BridgedNFTs.sol";

contract BridgedNFTsHandler is Test {
    BridgedNFTs public immutable nft;
    address[3] public users;
    uint256[] public tokens;
    uint256 internal nextId = 1;

    constructor(BridgedNFTs _nft, address[3] memory _users) {
        nft = _nft;
        users = _users;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function tokenAt(uint256 i) external view returns (uint256) {
        return tokens[i];
    }

    function _owner(uint256 id) internal view returns (address) {
        try nft.ownerOf(id) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }

    function _pickToken(uint256 seed) internal view returns (uint256 id, address holder) {
        if (tokens.length == 0) return (0, address(0));
        id = tokens[bound(seed, 0, tokens.length - 1)];
        holder = _owner(id);
    }

    // Handler is the sequencer + owner.
    function mint(uint256 toSeed) public {
        address to = users[bound(toSeed, 0, 2)];
        uint256 id = nextId++;
        try nft.sequencerMint(to, id) {
            tokens.push(id);
        } catch {}
    }

    function seqTransfer(uint256 tokenSeed, uint256 toSeed) public {
        (uint256 id, address holder) = _pickToken(tokenSeed);
        if (holder == address(0)) return;
        address to = users[bound(toSeed, 0, 2)];
        try nft.sequencerTransfer(holder, to, id) {} catch {}
    }

    function seqBurn(uint256 tokenSeed) public {
        (uint256 id, address holder) = _pickToken(tokenSeed);
        if (holder == address(0)) return;
        try nft.sequencerBurn(id) {} catch {}
    }

    function release(uint256 tokenSeed) public {
        (uint256 id, address holder) = _pickToken(tokenSeed);
        if (holder == address(0)) return;
        try nft.sequencerReleaseSovereignty(id) {} catch {}
    }

    function userTransfer(uint256 tokenSeed, uint256 toSeed) public {
        (uint256 id, address holder) = _pickToken(tokenSeed);
        if (holder == address(0)) return;
        address to = users[bound(toSeed, 0, 2)];
        vm.prank(holder);
        try nft.transferFrom(holder, to, id) {} catch {}
    }

    function requestForce(uint256 tokenSeed) public {
        (uint256 id, address holder) = _pickToken(tokenSeed);
        if (holder == address(0)) return;
        vm.prank(holder);
        try nft.requestForceSovereignty(id) {} catch {}
    }

    function executeForce(uint256 tokenSeed) public {
        (uint256 id, address holder) = _pickToken(tokenSeed);
        if (holder == address(0)) return;
        vm.prank(holder);
        try nft.executeForceSovereignty(id) {} catch {}
    }

    function cancelForce(uint256 tokenSeed) public {
        (uint256 id, address holder) = _pickToken(tokenSeed);
        if (holder == address(0)) return;
        vm.prank(holder);
        try nft.cancelForceSovereignty(id) {} catch {}
    }

    function renounce(uint256 tokenSeed) public {
        (uint256 id, address holder) = _pickToken(tokenSeed);
        if (holder == address(0)) return;
        vm.prank(holder);
        try nft.userRenounceSovereignty(id) {} catch {}
    }

    function warp(uint256 secs) public {
        secs = bound(secs, 1, 10 days);
        vm.warp(block.timestamp + secs);
    }
}

contract BridgedNFTsInvariantTest is Test {
    BridgedNFTs internal nft;
    BridgedNFTsHandler internal handler;
    address[3] internal users;

    function setUp() public {
        vm.warp(1_000_000);
        users = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];

        BridgedNFTs impl = new BridgedNFTs();
        handler = BridgedNFTsHandler(computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        nft = BridgedNFTs(
            address(
                new ERC1967Proxy(
                    address(impl),
                    // sequencer = owner = handler
                    abi.encodeCall(BridgedNFTs.initialize, ("Dual Network NFT", "DNFT", address(handler), address(handler), "ipfs://"))
                )
            )
        );
        BridgedNFTsHandler deployed = new BridgedNFTsHandler(nft, users);
        require(address(deployed) == address(handler), "handler addr mismatch");

        targetContract(address(handler));
    }

    /// @notice Enumerable supply equals the sum of holder balances (all tokens
    ///         are accounted to a known holder; none are orphaned).
    function invariant_supplyEqualsHolderBalances() public view {
        uint256 sum = nft.balanceOf(users[0]) + nft.balanceOf(users[1]) + nft.balanceOf(users[2]);
        assertEq(nft.totalSupply(), sum, "supply != holder balances");
    }

    /// @notice A sovereign token never carries a pending force-sovereignty request
    ///         (granting/claiming sovereignty clears any request).
    function invariant_sovereignHasNoPendingRequest() public view {
        for (uint256 i; i < handler.tokenCount(); i++) {
            uint256 id = handler.tokenAt(i);
            if (nft.isUserSovereign(id)) {
                assertEq(nft.forceSovereigntyRequestTime(id), 0, "sovereign with pending request");
            }
        }
    }

    /// @notice Force-request time and requester are always set/cleared together.
    function invariant_forceRequestFieldsPaired() public view {
        for (uint256 i; i < handler.tokenCount(); i++) {
            uint256 id = handler.tokenAt(i);
            bool hasTime = nft.forceSovereigntyRequestTime(id) != 0;
            bool hasRequester = nft.forceSovereigntyRequester(id) != address(0);
            assertEq(hasTime, hasRequester, "force request fields desynced");
        }
    }

    /// @notice Enumerable integrity: every index < totalSupply maps to a live token.
    function invariant_enumerableIndexesValid() public view {
        uint256 supply = nft.totalSupply();
        for (uint256 i; i < supply; i++) {
            uint256 id = nft.tokenByIndex(i);
            assertTrue(nft.ownerOf(id) != address(0), "enumerable index has no owner");
        }
    }
}
