// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {FeeSource} from "./libraries/FeeSource.sol";
import {IVault} from "./interfaces/IVault.sol";

contract FeeDispatcher is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    struct FeeRecipient {
        address payable recipient;
        uint256 basisPoints;
    }

    uint256 public constant MAX_RECIPIENTS = 20;
    uint256 public constant BPS_DENOMINATOR = 10000;

    address public vault;
    address public batchRegistry;
    address public ledger;

    FeeRecipient[] public recipients;

    uint256 public totalFeesDispatched;
    uint256 public totalFeesDistributed;
    uint256 public totalFeesRetained;

    event FeeDispatched(bytes32 indexed sourceId, uint8 indexed sourceType, uint256 distributed, uint256 retained);
    event FeeDistributed(address indexed recipient, uint256 amount, bytes32 indexed sourceId);
    event FeeDistributionFailed(address indexed recipient, uint256 amount, bytes32 indexed sourceId);
    event FeeWithdrawalFailed(bytes32 indexed sourceId, uint8 sourceType, uint256 fee);
    event FeesRetained(uint256 amount, bytes32 indexed sourceId);

    event RecipientAdded(address indexed recipient, uint256 basisPoints, uint256 index);
    event RecipientUpdated(uint256 indexed index, address indexed recipient, uint256 basisPoints);
    event RecipientRemoved(uint256 indexed index, address indexed recipient);

    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event BatchRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event LedgerUpdated(address indexed oldLedger, address indexed newLedger);
    event EmergencyWithdrawal(address indexed to, uint256 amount);

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidBasisPoints();
    error BasisPointsExceeded();
    error TooManyRecipients();
    error InvalidIndex();
    error TransferFailed();
    error InsufficientBalance();
    error UnchangedValue();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _vault, address _batchRegistry, address _ledger) public initializer {
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        vault = _vault;
        batchRegistry = _batchRegistry;
        ledger = _ledger;

        if (_vault != address(0)) emit VaultUpdated(address(0), _vault);
        if (_batchRegistry != address(0)) {
            emit BatchRegistryUpdated(address(0), _batchRegistry);
        }
        if (_ledger != address(0)) emit LedgerUpdated(address(0), _ledger);
    }

    modifier onlyAuthorized() {
        if (msg.sender != batchRegistry && msg.sender != ledger) {
            revert Unauthorized();
        }
        _;
    }

    // -------- Dispatch --------

    function dispatchFee(bytes32 batchHash, uint256 fee)
        external
        nonReentrant
        whenNotPaused
        onlyAuthorized
        returns (bool success)
    {
        if (fee == 0) return true;

        try IVault(vault).withdrawForFeeDistribution(fee, FeeSource.BATCH) {
            _dispatchFee(batchHash, FeeSource.BATCH, fee);
            return true;
        } catch {
            emit FeeWithdrawalFailed(batchHash, FeeSource.BATCH, fee);
            return false;
        }
    }

    /// @notice Distribute ledger fees. DUAL is pushed by the Ledger (msg.value == fee);
    ///         no Vault withdrawal is performed.
    function dispatchLedgerFee(bytes32 sourceId, uint256 fee)
        external
        payable
        nonReentrant
        whenNotPaused
        onlyAuthorized
        returns (bool success)
    {
        if (fee == 0) return true;
        if (msg.value != fee) revert ZeroAmount(); // enforce caller sent exactly the declared fee

        _dispatchFee(sourceId, FeeSource.LEDGER, fee);
        return true;
    }

    function _dispatchFee(bytes32 sourceId, uint8 sourceType, uint256 fee) internal {
        uint256 distributed;
        uint256 len = recipients.length;

        for (uint256 i = 0; i < len; i++) {
            FeeRecipient storage r = recipients[i];
            uint256 amount = (fee * r.basisPoints) / BPS_DENOMINATOR;
            if (amount == 0) continue;

            (bool success,) = r.recipient.call{value: amount}("");

            if (success) {
                distributed += amount;
                emit FeeDistributed(r.recipient, amount, sourceId);
            } else {
                emit FeeDistributionFailed(r.recipient, amount, sourceId);
            }
        }

        uint256 retained = fee - distributed;

        totalFeesDispatched += fee;
        totalFeesDistributed += distributed;
        totalFeesRetained += retained;

        if (retained > 0) emit FeesRetained(retained, sourceId);
        emit FeeDispatched(sourceId, sourceType, distributed, retained);
    }

    function addRecipient(address payable recipient, uint256 basisPoints) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (basisPoints == 0 || basisPoints > BPS_DENOMINATOR) {
            revert InvalidBasisPoints();
        }
        if (recipients.length >= MAX_RECIPIENTS) revert TooManyRecipients();

        recipients.push(FeeRecipient({recipient: recipient, basisPoints: basisPoints}));

        _validateBasisPointsSum();

        emit RecipientAdded(recipient, basisPoints, recipients.length - 1);
    }

    function updateRecipient(uint256 index, address payable recipient, uint256 basisPoints) external onlyOwner {
        if (index >= recipients.length) revert InvalidIndex();
        if (recipient == address(0)) revert ZeroAddress();
        if (basisPoints == 0 || basisPoints > BPS_DENOMINATOR) {
            revert InvalidBasisPoints();
        }

        recipients[index].recipient = recipient;
        recipients[index].basisPoints = basisPoints;

        _validateBasisPointsSum();

        emit RecipientUpdated(index, recipient, basisPoints);
    }

    function removeRecipient(uint256 index) external onlyOwner {
        if (index >= recipients.length) revert InvalidIndex();

        address recipient = recipients[index].recipient;

        recipients[index] = recipients[recipients.length - 1];
        recipients.pop();

        emit RecipientRemoved(index, recipient);
    }

    function _validateBasisPointsSum() internal view {
        uint256 sum;
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; i++) {
            sum += recipients[i].basisPoints;
        }
        if (sum > BPS_DENOMINATOR) revert BasisPointsExceeded();
    }

    function getRecipients() external view returns (FeeRecipient[] memory) {
        return recipients;
    }

    function getRecipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function totalBasisPoints() external view returns (uint256 sum) {
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; i++) {
            sum += recipients[i].basisPoints;
        }
    }

    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        if (_vault == vault) revert UnchangedValue();
        emit VaultUpdated(vault, _vault);
        vault = _vault;
    }

    function setBatchRegistry(address _batchRegistry) external onlyOwner {
        if (_batchRegistry == address(0)) revert ZeroAddress();
        if (_batchRegistry == batchRegistry) revert UnchangedValue();
        emit BatchRegistryUpdated(batchRegistry, _batchRegistry);
        batchRegistry = _batchRegistry;
    }

    function setLedger(address _ledger) external onlyOwner {
        if (_ledger == address(0)) revert ZeroAddress();
        if (_ledger == ledger) revert UnchangedValue();
        emit LedgerUpdated(ledger, _ledger);
        ledger = _ledger;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > address(this).balance) revert InsufficientBalance();

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit EmergencyWithdrawal(to, amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    receive() external payable {}

    uint256[45] private __gap;
}
