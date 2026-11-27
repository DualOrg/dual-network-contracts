// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {IFeeDispatcher} from "./interfaces/IFeeDispatcher.sol";

contract BatchRegistry is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    struct BatchInfo {
        bytes32 integrityRoot;
        uint256 batchNumber;
        uint256 timestamp;
        address challenger;
        uint256 challengeBondAmount;
        uint256 fee;
        bool isFinalized;
        bool isChallenged;
        bool feeDispatched;
    }

    uint256 public challengeWindow;
    uint256 public challengeBond;
    bool public haltOnFraud;

    address public sequencer;
    ISP1Verifier public zkVerifier;
    bytes32 public fraudProofVKey;
    bytes32 public checkpointVKey;

    uint256 public batchCount;
    bytes32 public lastBatchHash;
    bytes32 public lastIntegrityRoot;
    uint256 public highestFinalizedBatchNumber;

    bytes32 public lastCheckpointBatchHash;
    uint256 public lastCheckpointBatchNumber;

    mapping(bytes32 => BatchInfo) public batches;

    IFeeDispatcher public feeDispatcher;

    uint256 public totalActiveBonds;
    mapping(address => uint256) public pendingWithdrawals;
    uint256 public totalPendingWithdrawals;
    mapping(bytes32 => uint256) public pendingFeeDispatch;

    /// @notice Batch hash per batch number. Written at commit; the upgrade backfills the batches
    ///         pending at upgrade time. Batches finalized before the upgrade have no entry.
    mapping(uint256 => bytes32) public batchHashByNumber;
    /// @notice Owner-set floor for `challengeBond`.
    uint256 public minChallengeBond;
    /// @notice Longest range (end batch number minus start batch number) one checkpoint may cover.
    uint256 public maxCheckpointBatches;

    event BatchAnchored(
        uint256 indexed batchNumber,
        bytes32 indexed batchHash,
        bytes32 indexed integrityRoot,
        bytes32 prevBatchHash,
        bytes32 prevIntegrityRoot,
        bytes32 proofHash,
        string dataUri,
        uint256 fee,
        bool isVerified
    );

    event BatchChallenged(uint256 indexed batchNumber, address indexed challenger, uint256 bondAmount);

    event ChallengeResolved(uint256 indexed batchNumber, bool indexed sequencerWasCorrect, uint256 bondAmount);

    event FraudDetected(uint256 indexed batchNumber, address indexed challenger);
    event BatchFinalized(uint256 indexed batchNumber, bytes32 indexed batchHash);

    /// @notice Phase A checkpoint, emitted by `recordCheckpoint` before the checkpoint upgrade.
    ///         No longer emitted; kept so the ABI decodes the phase A logs.
    event CheckpointRecorded(
        bytes32 indexed startBatchHash,
        bytes32 indexed endBatchHash,
        uint256 batchNumber,
        bytes32 proofHash,
        string dataUri
    );

    /// @notice A validity checkpoint proved the range from `startBatchHash` to `endBatchHash`
    ///         and finalized every batch of it that was not finalized yet.
    event CheckpointFinalized(
        bytes32 indexed startBatchHash,
        bytes32 indexed endBatchHash,
        uint256 batchNumber,
        bytes32 proofHash,
        string dataUri
    );

    /// @notice Emitted once by `reinitializeCheckpoints`: the first finalizing checkpoint starts at
    ///         `startBatchHash`, the end of the last phase A checkpoint.
    event FinalizingCheckpointsStarted(bytes32 indexed startBatchHash, uint256 startBatchNumber);

    event MinChallengeBondUpdated(uint256 oldMinimum, uint256 newMinimum);
    event MaxCheckpointBatchesUpdated(uint256 oldMaximum, uint256 newMaximum);

    event ChallengeConfigUpdated(uint256 oldWindow, uint256 newWindow, uint256 oldBond, uint256 newBond);
    event VKeysUpdated(bytes32 oldFraudKey, bytes32 newFraudKey, bytes32 oldCheckpointKey, bytes32 newCheckpointKey);
    event SequencerUpdated(address indexed oldSequencer, address indexed newSequencer);
    event FeeDispatcherUpdated(address indexed oldDispatcher, address indexed newDispatcher);
    event HaltOnFraudUpdated(bool oldValue, bool newValue);

    event EmergencyWithdrawal(address indexed recipient, uint256 amount);
    event WithdrawalClaimed(address indexed recipient, uint256 amount);

    event FeeDispatchSucceeded(bytes32 indexed batchHash, uint256 fee);
    event FeeDispatchFailed(bytes32 indexed batchHash, uint256 fee);
    event FeeDispatchRetried(bytes32 indexed batchHash, uint256 fee);

    event BatchStateRewritten(
        bytes32 oldLastBatchHash,
        bytes32 newLastBatchHash,
        bytes32 oldLastIntegrityRoot,
        bytes32 newLastIntegrityRoot,
        uint256 oldHighestFinalizedBatchNumber,
        uint256 newHighestFinalizedBatchNumber
    );

    event CheckpointStateRewritten(
        bytes32 oldLastCheckpointBatchHash,
        bytes32 newLastCheckpointBatchHash,
        uint256 oldLastCheckpointBatchNumber,
        uint256 newLastCheckpointBatchNumber
    );

    error InvalidInput();
    error Unauthorized();
    error ChallengePeriodActive();
    error BatchNotChallenged();
    error AlreadyChallenged();
    error AlreadyFinalized();
    error CheckpointRangeTooLong();
    error CheckpointNotAtFinalized();
    error UseFinalizeCheckpoint();
    error BondTooLow();
    error BondBelowMinimum();
    error ChainBroken();
    error EmptyDataURI();
    error TransferFailed();
    error InvalidProof();
    error UnchangedValue();
    error MustBePaused();
    error NoPendingDispatch();
    error NothingToClaim();
    error NoSurplus();
    error AmountExceedsSurplus();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlySequencer() {
        if (msg.sender != sequencer) revert Unauthorized();
        _;
    }

    function initialize(
        address _owner,
        address _sequencer,
        address _zkVerifier,
        bytes32 _fraudProofVKey,
        bytes32 _checkpointVKey,
        uint256 _challengeWindow,
        uint256 _challengeBond
    ) public initializer {
        if (_owner == address(0)) revert InvalidInput();
        if (_sequencer == address(0)) revert InvalidInput();
        if (_zkVerifier == address(0)) revert InvalidInput();
        if (_challengeWindow == 0) revert InvalidInput();

        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        sequencer = _sequencer;
        zkVerifier = ISP1Verifier(_zkVerifier);
        fraudProofVKey = _fraudProofVKey;
        checkpointVKey = _checkpointVKey;
        challengeWindow = _challengeWindow;
        challengeBond = _challengeBond;
        haltOnFraud = true;
    }

    /// @notice Upgrade step to finalizing checkpoints. Run atomically through `upgradeToAndCall`
    ///         (or once after `initialize` on a fresh deployment, with an empty list).
    /// @dev    Requires the last phase A checkpoint to end at the highest finalized batch, so the
    ///         first finalizing checkpoint starts there. Never calls `setCheckpointState`.
    /// @param  pendingBatchHashes The hashes of every batch committed but not finalized, in batch
    ///         number order (`highestFinalizedBatchNumber + 1` to `batchCount`).
    /// @param  _minChallengeBond The challenge bond floor; `challengeBond` must not be below it.
    /// @param  _maxCheckpointBatches The longest range one checkpoint may cover.
    function reinitializeCheckpoints(
        bytes32[] calldata pendingBatchHashes,
        uint256 _minChallengeBond,
        uint256 _maxCheckpointBatches
    ) external onlyOwner reinitializer(2) {
        uint256 finalized = highestFinalizedBatchNumber;
        if (lastCheckpointBatchNumber != finalized || batches[lastCheckpointBatchHash].batchNumber != finalized) {
            revert CheckpointNotAtFinalized();
        }
        if (pendingBatchHashes.length != batchCount - finalized) revert InvalidInput();
        for (uint256 i = 0; i < pendingBatchHashes.length; i++) {
            bytes32 batchHash = pendingBatchHashes[i];
            if (batches[batchHash].batchNumber != finalized + 1 + i) revert InvalidInput();
            batchHashByNumber[finalized + 1 + i] = batchHash;
        }

        setMinChallengeBond(_minChallengeBond);
        setMaxCheckpointBatches(_maxCheckpointBatches);

        emit FinalizingCheckpointsStarted(lastCheckpointBatchHash, finalized);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function commitBatch(
        bytes32 prevBatchHash,
        bytes32 commitment,
        bytes32 integrityRoot,
        string calldata dataUri,
        uint256 fee
    ) external onlySequencer whenNotPaused {
        if (commitment == bytes32(0) || integrityRoot == bytes32(0)) {
            revert InvalidInput();
        }
        if (bytes(dataUri).length == 0) revert EmptyDataURI();
        if (prevBatchHash != lastBatchHash) revert ChainBroken();

        bytes32 batchHash = EfficientHashLib.sha2(abi.encodePacked(prevBatchHash, commitment));

        _processBatchCommit(batchHash, integrityRoot, dataUri, fee, false, bytes32(0));
    }

    function commitBatchWithProof(
        bytes32 prevBatchHash,
        bytes32 commitment,
        bytes32 integrityRoot,
        bytes calldata proofBytes,
        bytes calldata publicValues,
        string calldata dataUri,
        uint256 fee
    ) external onlySequencer whenNotPaused {
        if (commitment == bytes32(0) || integrityRoot == bytes32(0)) {
            revert InvalidInput();
        }
        if (bytes(dataUri).length == 0) revert EmptyDataURI();
        if (prevBatchHash != lastBatchHash) revert ChainBroken();

        zkVerifier.verifyProof(fraudProofVKey, publicValues, proofBytes);

        {
            (bytes32 provedPrevHash, bytes32 provedCommitment, bytes32 provedIntegrityRoot) =
                abi.decode(publicValues, (bytes32, bytes32, bytes32));

            if (provedPrevHash != prevBatchHash) revert InvalidProof();
            if (provedCommitment != commitment) revert InvalidProof();
            if (provedIntegrityRoot != integrityRoot) revert InvalidProof();
        }

        _processBatchCommit(
            EfficientHashLib.sha2(abi.encodePacked(prevBatchHash, commitment)),
            integrityRoot,
            dataUri,
            fee,
            true,
            EfficientHashLib.hash(proofBytes)
        );
    }

    function _processBatchCommit(
        bytes32 batchHash,
        bytes32 integrityRoot,
        string calldata dataUri,
        uint256 fee,
        bool isVerified,
        bytes32 proofHash
    ) internal {
        uint256 batchNumber = batchCount + 1;
        bytes32 prevBatchHash = lastBatchHash;
        bytes32 prevIntegrityRoot = lastIntegrityRoot;

        batches[batchHash] = BatchInfo({
            integrityRoot: integrityRoot,
            batchNumber: batchNumber,
            timestamp: block.timestamp,
            challenger: address(0),
            challengeBondAmount: 0,
            fee: fee,
            isFinalized: false,
            isChallenged: false,
            feeDispatched: false
        });

        batchCount = batchNumber;
        batchHashByNumber[batchNumber] = batchHash;
        lastBatchHash = batchHash;
        lastIntegrityRoot = integrityRoot;

        emit BatchAnchored(
            batchNumber, batchHash, integrityRoot, prevBatchHash, prevIntegrityRoot, proofHash, dataUri, fee, isVerified
        );

        if (isVerified) {
            _finalize(batchHash, batchNumber, fee);
        }
    }

    function challengeBatch(bytes32 batchHash) external payable nonReentrant whenNotPaused {
        BatchInfo storage batch = batches[batchHash];

        if (batch.timestamp == 0) revert InvalidInput();
        if (batch.isFinalized) revert AlreadyFinalized();
        if (batch.isChallenged) revert AlreadyChallenged();
        if (msg.value < challengeBond) revert BondTooLow();

        if (block.timestamp >= batch.timestamp + challengeWindow) {
            revert ChallengePeriodActive(); // (window closed; finalize instead)
        }

        batch.isChallenged = true;
        batch.challenger = msg.sender;
        batch.challengeBondAmount = msg.value;
        totalActiveBonds += msg.value;

        emit BatchChallenged(batch.batchNumber, msg.sender, msg.value);
    }

    function resolveChallenge(bytes32 batchHash, bytes calldata proofBytes, bytes calldata publicValues)
        external
        nonReentrant
    {
        BatchInfo storage batch = batches[batchHash];
        if (batch.timestamp == 0) revert InvalidInput();
        if (!batch.isChallenged) revert BatchNotChallenged();

        zkVerifier.verifyProof(fraudProofVKey, publicValues, proofBytes);

        (bytes32 provedPrevHash, bytes32 provedCommitment, bytes32 provedIntegrityRoot) =
            abi.decode(publicValues, (bytes32, bytes32, bytes32));

        bytes32 provedBatchHash = EfficientHashLib.sha2(abi.encodePacked(provedPrevHash, provedCommitment));
        if (provedBatchHash != batchHash) revert InvalidProof();

        bool sequencerWasCorrect = (provedIntegrityRoot == batch.integrityRoot);

        uint256 bondAmount = batch.challengeBondAmount;
        uint256 batchNumber = batch.batchNumber;
        address challenger = batch.challenger;

        batch.isChallenged = false;
        batch.challengeBondAmount = 0;
        totalActiveBonds -= bondAmount;

        if (sequencerWasCorrect) {
            pendingWithdrawals[sequencer] += bondAmount;
            totalPendingWithdrawals += bondAmount;
            _finalize(batchHash, batchNumber, batch.fee);
        } else {
            pendingWithdrawals[challenger] += bondAmount;
            totalPendingWithdrawals += bondAmount;
            if (haltOnFraud) _pause();
            emit FraudDetected(batchNumber, challenger);
        }

        emit ChallengeResolved(batchNumber, sequencerWasCorrect, bondAmount);
    }

    function finalizeBatch(bytes32 batchHash) external whenNotPaused {
        BatchInfo storage batch = batches[batchHash];

        if (batch.timestamp == 0) revert InvalidInput();
        if (batch.isFinalized) revert AlreadyFinalized();
        if (batch.isChallenged) revert AlreadyChallenged();

        // M-2 fix: aligned with challengeBatch boundary.
        if (block.timestamp < batch.timestamp + challengeWindow) {
            revert ChallengePeriodActive();
        }

        _finalize(batchHash, batch.batchNumber, batch.fee);
    }

    function _finalize(bytes32 batchHash, uint256 batchNumber, uint256 fee) internal {
        BatchInfo storage batch = batches[batchHash];
        if (batchNumber != highestFinalizedBatchNumber + 1) {
            revert ChainBroken();
        }

        batch.isFinalized = true;

        highestFinalizedBatchNumber = batchNumber;

        emit BatchFinalized(batchNumber, batchHash);

        if (fee == 0) {
            batch.feeDispatched = true;
        } else if (address(feeDispatcher) == address(0)) {
            pendingFeeDispatch[batchHash] = fee;
            emit FeeDispatchFailed(batchHash, fee);
        } else {
            try feeDispatcher.dispatchFee(batchHash, fee) returns (bool dispatched) {
                if (!dispatched) {
                    pendingFeeDispatch[batchHash] = fee;
                    emit FeeDispatchFailed(batchHash, fee);
                    return;
                }
                batch.feeDispatched = true;
                emit FeeDispatchSucceeded(batchHash, fee);
            } catch {
                pendingFeeDispatch[batchHash] = fee;
                emit FeeDispatchFailed(batchHash, fee);
            }
        }
    }

    function retryDispatchFee(bytes32 batchHash) external nonReentrant {
        uint256 fee = pendingFeeDispatch[batchHash];
        if (fee == 0) revert NoPendingDispatch();
        if (address(feeDispatcher) == address(0)) revert NoPendingDispatch();

        delete pendingFeeDispatch[batchHash];

        try feeDispatcher.dispatchFee(batchHash, fee) returns (bool dispatched) {
            if (!dispatched) {
                pendingFeeDispatch[batchHash] = fee;
                emit FeeDispatchFailed(batchHash, fee);
                return;
            }
            batches[batchHash].feeDispatched = true;
            emit FeeDispatchRetried(batchHash, fee);
            emit FeeDispatchSucceeded(batchHash, fee);
        } catch {
            pendingFeeDispatch[batchHash] = fee;
            emit FeeDispatchFailed(batchHash, fee);
        }
    }

    function claimWithdrawal() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToClaim();

        pendingWithdrawals[msg.sender] = 0;
        totalPendingWithdrawals -= amount;

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) {
            pendingWithdrawals[msg.sender] = amount;
            totalPendingWithdrawals += amount;
            revert TransferFailed();
        }

        emit WithdrawalClaimed(msg.sender, amount);
    }

    /// @notice Removed by the checkpoint upgrade; use `finalizeCheckpoint`.
    function recordCheckpoint(bytes calldata, bytes calldata, string calldata) external pure {
        revert UseFinalizeCheckpoint();
    }

    /// @notice Verifies a validity checkpoint proof and finalizes every batch of its range that is
    ///         not finalized yet, in order, with fee dispatch. A challenge on a batch in the range is
    ///         cleared and its bond credited to the sequencer, as `resolveChallenge` does when the
    ///         sequencer was correct.
    /// @param  publicValues `abi.encode(startHash, startIntegrityRoot, endHash, endIntegrityRoot)`.
    ///         `startHash` must be `lastCheckpointBatchHash`; `endHash` a committed batch after it.
    function finalizeCheckpoint(bytes calldata proofBytes, bytes calldata publicValues, string calldata dataUri)
        external
        nonReentrant
        whenNotPaused
    {
        zkVerifier.verifyProof(checkpointVKey, publicValues, proofBytes);

        (bytes32 startHash, bytes32 startIntegrityRoot, bytes32 endHash, bytes32 endIntegrityRoot) =
            abi.decode(publicValues, (bytes32, bytes32, bytes32, bytes32));

        if (startHash != lastCheckpointBatchHash) revert ChainBroken();
        uint256 startNumber = lastCheckpointBatchNumber;
        // Every batch the loop finalizes must lie inside the proved range.
        if (startNumber > highestFinalizedBatchNumber) revert ChainBroken();

        BatchInfo storage endBatch = batches[endHash];
        uint256 endNumber = endBatch.batchNumber;
        if (endBatch.timestamp == 0 || endNumber <= startNumber) revert InvalidInput();
        if (endNumber - startNumber > maxCheckpointBatches) revert CheckpointRangeTooLong();
        if (batches[startHash].integrityRoot != startIntegrityRoot) revert InvalidProof();
        if (endBatch.integrityRoot != endIntegrityRoot) revert InvalidProof();

        lastCheckpointBatchHash = endHash;
        lastCheckpointBatchNumber = endNumber;

        for (uint256 n = highestFinalizedBatchNumber + 1; n <= endNumber; n++) {
            bytes32 batchHash = batchHashByNumber[n];
            BatchInfo storage batch = batches[batchHash];
            if (batch.isChallenged) {
                uint256 bondAmount = batch.challengeBondAmount;
                batch.isChallenged = false;
                batch.challengeBondAmount = 0;
                totalActiveBonds -= bondAmount;
                pendingWithdrawals[sequencer] += bondAmount;
                totalPendingWithdrawals += bondAmount;
                emit ChallengeResolved(n, true, bondAmount);
            }
            _finalize(batchHash, n, batch.fee);
        }

        emit CheckpointFinalized(startHash, endHash, endNumber, EfficientHashLib.hash(proofBytes), dataUri);
    }

    function setVKeys(bytes32 _fraudKey, bytes32 _checkpointKey) external onlyOwner {
        emit VKeysUpdated(fraudProofVKey, _fraudKey, checkpointVKey, _checkpointKey);
        fraudProofVKey = _fraudKey;
        checkpointVKey = _checkpointKey;
    }

    function setSequencer(address _sequencer) external onlyOwner {
        if (_sequencer == address(0)) revert InvalidInput();
        if (_sequencer == sequencer) revert UnchangedValue();
        emit SequencerUpdated(sequencer, _sequencer);
        sequencer = _sequencer;
    }

    function setFeeDispatcher(address _dispatcher) external onlyOwner {
        if (_dispatcher == address(feeDispatcher)) revert UnchangedValue();
        emit FeeDispatcherUpdated(address(feeDispatcher), _dispatcher);
        feeDispatcher = IFeeDispatcher(_dispatcher);
    }

    function setChallengeConfig(uint256 _window, uint256 _bond) external onlyOwner {
        if (_window == 0) revert InvalidInput();
        if (_bond < minChallengeBond) revert BondBelowMinimum();
        emit ChallengeConfigUpdated(challengeWindow, _window, challengeBond, _bond);
        challengeWindow = _window;
        challengeBond = _bond;
    }

    /// @notice Sets the challenge bond floor. The current `challengeBond` must not be below it.
    function setMinChallengeBond(uint256 _minimum) public onlyOwner {
        if (challengeBond < _minimum) revert BondBelowMinimum();
        emit MinChallengeBondUpdated(minChallengeBond, _minimum);
        minChallengeBond = _minimum;
    }

    /// @notice Sets the longest range one checkpoint may cover, the gas bound of `finalizeCheckpoint`.
    function setMaxCheckpointBatches(uint256 _maximum) public onlyOwner {
        if (_maximum == 0) revert InvalidInput();
        emit MaxCheckpointBatchesUpdated(maxCheckpointBatches, _maximum);
        maxCheckpointBatches = _maximum;
    }

    function setHaltOnFraud(bool _halt) external onlyOwner {
        if (_halt == haltOnFraud) revert UnchangedValue();
        emit HaltOnFraudUpdated(haltOnFraud, _halt);
        haltOnFraud = _halt;
    }

    function setBatchState(bytes32 _lastBatchHash, bytes32 _lastIntegrityRoot, uint256 _highestFinalizedBatchNumber)
        external
        onlyOwner
        whenPaused
    {
        if (_lastBatchHash != bytes32(0)) {
            BatchInfo storage b = batches[_lastBatchHash];
            if (b.timestamp == 0) revert InvalidInput();
            if (b.integrityRoot != _lastIntegrityRoot) revert InvalidInput();
        }

        emit BatchStateRewritten(
            lastBatchHash,
            _lastBatchHash,
            lastIntegrityRoot,
            _lastIntegrityRoot,
            highestFinalizedBatchNumber,
            _highestFinalizedBatchNumber
        );

        lastBatchHash = _lastBatchHash;
        lastIntegrityRoot = _lastIntegrityRoot;
        highestFinalizedBatchNumber = _highestFinalizedBatchNumber;
    }

    function setCheckpointState(bytes32 _lastCheckpointBatchHash, uint256 _lastCheckpointBatchNumber)
        external
        onlyOwner
        whenPaused
    {
        if (_lastCheckpointBatchHash != bytes32(0)) {
            BatchInfo storage b = batches[_lastCheckpointBatchHash];
            if (b.timestamp == 0) revert InvalidInput();
            if (b.batchNumber != _lastCheckpointBatchNumber) {
                revert InvalidInput();
            }
        }

        emit CheckpointStateRewritten(
            lastCheckpointBatchHash, _lastCheckpointBatchHash, lastCheckpointBatchNumber, _lastCheckpointBatchNumber
        );

        lastCheckpointBatchHash = _lastCheckpointBatchHash;
        lastCheckpointBatchNumber = _lastCheckpointBatchNumber;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address payable recipient, uint256 amount) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert InvalidInput();
        if (amount == 0) revert InvalidInput();

        uint256 surplus = withdrawableSurplus();
        if (surplus == 0) revert NoSurplus();
        if (amount > surplus) revert AmountExceedsSurplus();

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit EmergencyWithdrawal(recipient, amount);
    }

    function getBatchInfo(bytes32 batchHash) external view returns (BatchInfo memory) {
        return batches[batchHash];
    }

    function isBatchFinalized(bytes32 batchHash) external view returns (bool) {
        if (batches[batchHash].timestamp == 0) return false;
        return batches[batchHash].isFinalized;
    }

    function getLastCheckpoint() external view returns (bytes32 batchHash, uint256 batchNumber) {
        return (lastCheckpointBatchHash, lastCheckpointBatchNumber);
    }

    function withdrawableSurplus() public view returns (uint256) {
        uint256 reserved = totalActiveBonds + totalPendingWithdrawals;
        uint256 balance = address(this).balance;
        if (balance <= reserved) return 0;
        return balance - reserved;
    }

    receive() external payable {}

    uint256[30] private __gap;
}
