// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IFeeDispatcher} from "./interfaces/IFeeDispatcher.sol";
import {ILedger} from "./interfaces/ILedger.sol";

/// @title Ledger
/// @notice Partner accounting and escrow. The owner funds native DUAL;
///         on each action the fee is split: the FeeDispatcher share is pushed
///         via `dispatchLedgerFee{value}` so FeeDispatcher can run its own
///         distribution logic, and the treasury share is sent directly.
contract Ledger is
    Initializable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ILedger
{
    bytes32 public constant SENDER_ROLE = keccak256("SENDER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_FEE_DISPATCHER_BPS = 5_000;

    /// @notice FeeDispatcher — receives its share of each action fee via DUAL push.
    IFeeDispatcher public feeDispatcher;

    /// @notice Treasury address — receives the remainder of each action fee.
    address public treasury;

    /// @notice Basis points sent to feeDispatcher (rest goes to treasury). Default 5000 = 50%.
    uint256 public feeDispatcherBps;

    /// @notice Total native DUAL ever deposited into this contract.
    uint256 public totalDeposited;

    /// @notice Total fee records processed.
    uint256 public totalRecords;

    /// @notice Total fees processed across all records.
    uint256 public totalFees;

    /// @notice Number of single-fee records processed.
    uint256 public totalSingleRecords;

    /// @notice Number of snapshot payloads processed.
    uint256 public totalSnapshots;

    /// @notice Cumulative fees successfully sent to FeeDispatcher.
    uint256 public dispatchedFees;

    /// @notice Cumulative fees successfully sent to Treasury.
    uint256 public treasuryFees;

    mapping(bytes32 => bool) public processedRefIds;

    event Deposited(address indexed partner, uint256 amount);
    event SingleFeeProcessed(bytes32 indexed refId, uint256 indexed tokenId, uint256 fee, uint256 timestamp);
    event SnapshotFeeProcessed(
        bytes32 indexed refId,
        bytes32 from,
        bytes32 to,
        uint256 entriesCount,
        uint256 fee,
        bytes32 digest
    );
    event FeeDispatched(bytes32 indexed refId, uint256 toDispatcher, uint256 toTreasury);
    event FeeDispatcherUpdated(address indexed oldDispatcher, address indexed newDispatcher);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SplitUpdated(uint256 oldFeeDispatcherBps, uint256 newFeeDispatcherBps);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnchangedValue();
    error DuplicateRefId();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidBps();
    error InvalidEntriesCount();
    error FeeDispatcherNotSet();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address _feeDispatcher, address _sender, address _treasury) public initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (_sender == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        __Ownable_init(admin);
        __Ownable2Step_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        feeDispatcher = IFeeDispatcher(_feeDispatcher);
        treasury = _treasury;
        feeDispatcherBps = DEFAULT_FEE_DISPATCHER_BPS;

        _grantRole(SENDER_ROLE, _sender);

        if (_feeDispatcher != address(0)) emit FeeDispatcherUpdated(address(0), _feeDispatcher);
        emit TreasuryUpdated(address(0), _treasury);
    }

    /// @notice Deposit native DUAL into the Ledger to fund future action fees.
    /// @dev Restricted to owner so partner funds are controlled operationally.
    function deposit() external payable onlyOwner whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();
        totalDeposited += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    // -------- Fee Processing --------

    function processSingleFee(ILedger.SingleFeeParams calldata params)
        external
        override
        onlyRole(SENDER_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (processedRefIds[params.refId]) revert DuplicateRefId();
        processedRefIds[params.refId] = true;

        totalRecords += 1;
        totalSingleRecords += 1;
        totalFees += params.fee;

        emit SingleFeeProcessed(params.refId, params.tokenId, params.fee, params.timestamp);

        _dispatchFee(params.refId, params.fee);
    }

    function processSnapshotFee(ILedger.SnapshotFeeParams calldata params)
        external
        override
        onlyRole(SENDER_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (processedRefIds[params.refId]) revert DuplicateRefId();
        if (params.entriesCount == 0) revert InvalidEntriesCount();
        processedRefIds[params.refId] = true;

        totalRecords += params.entriesCount;
        totalSnapshots += 1;
        totalFees += params.fee;

        emit SnapshotFeeProcessed(
            params.refId, params.from, params.to, params.entriesCount, params.fee, params.digest
        );

        _dispatchFee(params.refId, params.fee);
    }

    function _dispatchFee(bytes32 refId, uint256 fee) internal {
        if (fee == 0) return;
        if (address(this).balance < fee) revert InsufficientBalance();

        uint256 toDispatcher = (fee * feeDispatcherBps) / BPS_DENOMINATOR;
        uint256 toTreasury = fee - toDispatcher;
        uint256 dispatched;

        if (toDispatcher > 0) {
            if (address(feeDispatcher) == address(0)) {
                revert FeeDispatcherNotSet();
            }
            bool ok = feeDispatcher.dispatchLedgerFee{value: toDispatcher}(refId, toDispatcher);
            if (!ok) revert TransferFailed();
            dispatched = toDispatcher;
        }

        if (toTreasury > 0) {
            (bool ok,) = treasury.call{value: toTreasury}("");
            if (!ok) revert TransferFailed();
        }

        dispatchedFees += dispatched;
        treasuryFees += toTreasury;

        emit FeeDispatched(refId, toDispatcher, toTreasury);
    }

    // -------- Admin --------

    function setFeeDispatcher(address _feeDispatcher) external onlyOwner {
        if (_feeDispatcher == address(feeDispatcher)) revert UnchangedValue();
        emit FeeDispatcherUpdated(address(feeDispatcher), _feeDispatcher);
        feeDispatcher = IFeeDispatcher(_feeDispatcher);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_treasury == treasury) revert UnchangedValue();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /// @notice Update the dispatcher/treasury split. _feeDispatcherBps is the share
    ///         going to feeDispatcher; treasury receives the remainder.
    function setSplit(uint256 _feeDispatcherBps) external onlyOwner {
        if (_feeDispatcherBps > BPS_DENOMINATOR) revert InvalidBps();
        if (_feeDispatcherBps == feeDispatcherBps) revert UnchangedValue();
        emit SplitUpdated(feeDispatcherBps, _feeDispatcherBps);
        feeDispatcherBps = _feeDispatcherBps;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientBalance();

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdrawn(address(0), to, amount);
    }

    function grantSenderRole(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(SENDER_ROLE, account);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[39] private __gap;
}
