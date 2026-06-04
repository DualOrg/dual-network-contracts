// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ERC721Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract BridgedNFTs is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721BurnableUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant FORCE_EXIT_DELAY = 7 days;

    address public sequencer;

    string private _baseTokenUri;

    mapping(uint256 tokenId => bool) public isUserSovereign;

    mapping(uint256 tokenId => uint256) public forceSovereigntyRequestTime;
    mapping(uint256 tokenId => address) public forceSovereigntyRequester;

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

    error ZeroAddress();
    error NotOwner();
    error AlreadySovereign();
    error NotSovereign();
    error TokenNotFound();
    error NotRequester();
    error NoActiveRequest();
    error TooEarly();
    error AlreadyRequested();
    error TransferRestricted();
    error UnchangedValue();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address sequencer_,
        address owner_,
        string memory initialBaseUri
    ) public initializer {
        if (sequencer_ == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();

        __ERC721_init(name_, symbol_);
        __ERC721Enumerable_init();
        __ERC721Burnable_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        sequencer = sequencer_;
        _baseTokenUri = initialBaseUri;

        emit SequencerUpdated(address(0), sequencer_);
        emit BaseUriSet("", initialBaseUri);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    modifier onlySequencer() {
        if (msg.sender != sequencer) revert TransferRestricted();
        _;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenUri;
    }

    function setBaseUri(string memory newBaseUri) external onlyOwner {
        emit BaseUriSet(_baseTokenUri, newBaseUri);
        _baseTokenUri = newBaseUri;
    }

    function name() public pure override returns (string memory) {
        return "Dual Network NFT";
    }

    function symbol() public pure override returns (string memory) {
        return "DNFT";
    }

    function setSequencer(address newSequencer) external onlyOwner {
        if (newSequencer == address(0)) revert ZeroAddress();
        if (newSequencer == sequencer) revert UnchangedValue();
        address oldSequencer = sequencer;
        sequencer = newSequencer;
        emit SequencerUpdated(oldSequencer, newSequencer);
    }

    function sequencerMint(
        address to,
        uint256 tokenId
    ) external onlySequencer whenNotPaused {
        _safeMint(to, tokenId);
    }

    function sequencerTransfer(
        address from,
        address to,
        uint256 tokenId
    ) external onlySequencer whenNotPaused {
        if (isUserSovereign[tokenId]) revert TransferRestricted();
        if (forceSovereigntyRequestTime[tokenId] != 0)
            revert TransferRestricted();
        _transfer(from, to, tokenId);
    }

    function sequencerBurn(
        uint256 tokenId
    ) external onlySequencer whenNotPaused {
        if (isUserSovereign[tokenId]) revert TransferRestricted();
        if (forceSovereigntyRequestTime[tokenId] != 0)
            revert TransferRestricted();
        _burn(tokenId);
    }

    function sequencerReleaseSovereignty(
        uint256 tokenId
    ) external onlySequencer {
        address holder = _ownerOf(tokenId);
        if (holder == address(0)) revert TokenNotFound();
        if (isUserSovereign[tokenId]) revert AlreadySovereign();

        isUserSovereign[tokenId] = true;

        if (forceSovereigntyRequestTime[tokenId] != 0) {
            forceSovereigntyRequestTime[tokenId] = 0;
            forceSovereigntyRequester[tokenId] = address(0);
        }

        emit SovereigntyReleased(tokenId, holder);
    }

    function requestForceSovereignty(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (isUserSovereign[tokenId]) revert AlreadySovereign();
        if (forceSovereigntyRequestTime[tokenId] != 0)
            revert AlreadyRequested();

        forceSovereigntyRequestTime[tokenId] = block.timestamp;
        forceSovereigntyRequester[tokenId] = msg.sender;

        emit ForceSovereigntyRequested(tokenId, msg.sender);
    }

    function executeForceSovereignty(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (isUserSovereign[tokenId]) revert AlreadySovereign();
        if (forceSovereigntyRequester[tokenId] != msg.sender)
            revert NotRequester();

        uint256 requestedAt = forceSovereigntyRequestTime[tokenId];
        if (requestedAt == 0) revert NoActiveRequest();
        if (block.timestamp <= requestedAt + FORCE_EXIT_DELAY)
            revert TooEarly();

        isUserSovereign[tokenId] = true;
        forceSovereigntyRequestTime[tokenId] = 0;
        forceSovereigntyRequester[tokenId] = address(0);

        emit SovereigntyForceClaimed(tokenId, msg.sender);
    }

    function cancelForceSovereignty(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (forceSovereigntyRequestTime[tokenId] == 0) revert NoActiveRequest();
        if (forceSovereigntyRequester[tokenId] != msg.sender)
            revert NotRequester();

        forceSovereigntyRequestTime[tokenId] = 0;
        forceSovereigntyRequester[tokenId] = address(0);

        emit ForceSovereigntyCancelled(tokenId, msg.sender);
    }

    function userRenounceSovereignty(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (!isUserSovereign[tokenId]) revert NotSovereign();
        isUserSovereign[tokenId] = false;
        emit SovereigntyRenounced(tokenId, msg.sender);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function isUserSovereignBatch(
        uint256[] calldata tokenIds
    ) external view returns (bool[] memory results) {
        results = new bool[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            results[i] = isUserSovereign[tokenIds[i]];
        }
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    )
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        address from = _ownerOf(tokenId);

        if (from != address(0) && msg.sender != sequencer) {
            if (!isUserSovereign[tokenId]) revert TransferRestricted();
        }

        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(
        address account,
        uint128 value
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    uint256[44] private __gap;
}
