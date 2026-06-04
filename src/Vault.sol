// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {FeeSource} from "./libraries/FeeSource.sol";

contract Vault is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    address public constant NATIVE_DUAL = address(0);

    bytes32 public constant FLOAT_DEPOSITOR_ROLE = keccak256("FLOAT_DEPOSITOR_ROLE");

    uint256 public totalWithdrawnForFees;
    address public feeDispatcher;

    event OrgDeposited(address indexed depositor, bytes32 indexed orgId, address indexed token, uint256 amount);
    event FloatDeposited(address indexed depositor, uint256 amount);
    event FeeWithdrawal(address indexed to, uint256 amount, uint8 sourceType);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event FeeDispatcherUpdated(address indexed oldDispatcher, address indexed newDispatcher);

    error ZeroAmount();
    error ZeroAddress();
    error Unauthorized();
    error InvalidToken();
    error InsufficientBalance();
    error TransferFailed();
    error ExceedsPerCallCap();
    error InvalidSourceType();
    error UnchangedValue();

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    modifier onlyFeeDispatcher() {
        if (msg.sender != feeDispatcher) revert Unauthorized();
        _;
    }

    function deposit(address token, bytes32 orgId, uint256 amount) external nonReentrant whenNotPaused {
        if (token == address(0)) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit OrgDeposited(msg.sender, orgId, token, amount);
    }

    function depositDual(bytes32 orgId) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();
        emit OrgDeposited(msg.sender, orgId, NATIVE_DUAL, msg.value);
    }

    function depositFloat() external payable nonReentrant whenNotPaused onlyRole(FLOAT_DEPOSITOR_ROLE) {
        if (msg.value == 0) revert ZeroAmount();
        emit FloatDeposited(msg.sender, msg.value);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function withdrawDual(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientBalance();

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdrawn(NATIVE_DUAL, to, amount);
    }

    function withdrawForFeeDistribution(uint256 amount, uint8 sourceType)
        external
        nonReentrant
        whenNotPaused
        onlyFeeDispatcher
        returns (bool)
    {
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientBalance();
        if (sourceType != FeeSource.BATCH && sourceType != FeeSource.LEDGER) {
            revert InvalidSourceType();
        }

        totalWithdrawnForFees += amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit FeeWithdrawal(msg.sender, amount, sourceType);
        return true;
    }

    function setFeeDispatcher(address newFeeDispatcher) external onlyOwner {
        if (newFeeDispatcher == address(0)) revert ZeroAddress();
        if (newFeeDispatcher == feeDispatcher) revert UnchangedValue();
        emit FeeDispatcherUpdated(feeDispatcher, newFeeDispatcher);
        feeDispatcher = newFeeDispatcher;
    }

    function grantFloatDepositorRole(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(FLOAT_DEPOSITOR_ROLE, account);
    }

    function revokeFloatDepositorRole(address account) external onlyOwner {
        _revokeRole(FLOAT_DEPOSITOR_ROLE, account);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    uint256[47] private __gap;
}
