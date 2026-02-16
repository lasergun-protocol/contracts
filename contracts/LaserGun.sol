// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ILaserGun} from "./interfaces/ILaserGun.sol";
import {ITypes} from "./interfaces/ITypes.sol";
import {ShieldOperations} from "./lib/ShieldOperations.sol";
import {EscrowOperations} from "./lib/EscrowOperations.sol";
import {Utils} from "./lib/Utils.sol";
import {ShieldFlags} from "./lib/ShieldFlags.sol";

/**
 * @title LaserGun
 * @author LaserGun Team
 * @notice Advanced contract for confidential transactions using commitments
 *         and zero-knowledge proofs
 * @notice The contract allows users to create shields for tokens, perform private
 *      transfers and consolidate funds
 *
 * Key functions:
 * - shield: deposit tokens into a private shield
 * - unshield: withdraw tokens from a shield
 * - transfer: private transfer between users
 * - consolidate: merge multiple shields into one
 *
 * Security features:
 * - Reentrancy protection
 * - Role-based access control
 * - Pause for emergency situations
 * - Upgradeable via UUPS pattern
 *
 * Gas costs:
 * - shield: ~150k-200k gas
 * - unshield: ~120k-180k gas
 * - transfer: ~180k-250k gas
 * - consolidate: ~200k-300k gas (depends on number of shields)
 */
contract LaserGun is
    Initializable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ILaserGun
{
    /// @notice Role identifiers for access control
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Mapping of commitment hashes to shield data
    mapping(bytes32 => ITypes.Shield) public shields;

    /// @notice Mapping of commitment hashes to escrow data
    mapping(bytes32 => ITypes.Escrow) public escrows;

    /// @notice User nonces for deterministic commitment generation
    mapping(address => uint64) public userNonces;

    /// @notice Public keys for encrypted secret delivery
    mapping(address => bytes) public publicKeys;
    
    /// @notice User operation tracking for rate limiting
    mapping(address => uint256) public userOperationCount;
    mapping(address => uint256) public userLastOperationTime;
    mapping(address => uint256) public userShieldCount;
    mapping(address => mapping(string => uint256)) public userLastOperationTimeByType;

    /// @notice Fee settings
    /// @notice Fee percentage in basis points (25 = 0.25%)
    uint16 public shieldFeePercent;
    /// @notice Fee percentage in basis points
    uint16 public unshieldFeePercent;
    /// @notice Fee percentage in basis points
    uint16 public transferFeePercent;

    /// @notice Token => accumulated fees mapping
    mapping(address => uint256) public collectedFees;

    /// @notice Constants
    /// @notice 10% maximum fee
    uint16 public constant MAX_FEE_PERCENT = 1000;
    /// @notice 100% = 10000 basis points
    uint16 public constant FEE_DENOMINATOR = 10000;
    /// @notice Maximum Shields in consolidate
    uint8 public constant MAX_CONSOLIDATE_SHIELDS = 10;
    /// @notice Minimum amount (1 wei) to prevent dust attacks
    uint64 public constant MIN_AMOUNT = 1;
    /// @notice Minimum confirmation period (1 hour) for escrow
    uint32 public constant MIN_CONFIRMATION_PERIOD = 3600;
    /// @notice Maximum confirmation period (30 days) for escrow
    uint32 public constant MAX_CONFIRMATION_PERIOD = 30 days;
    /// @notice Maximum amount for single operation (1 million tokens)
    uint256 public constant MAX_OPERATION_AMOUNT = 1_000_000 * 1e18;
    /// @notice Maximum shields per user
    uint256 public constant MAX_SHIELDS_PER_USER = 100;
    /// @notice Operation cooldown period (5 minutes) to prevent spam
    uint32 public constant OPERATION_COOLDOWN = 0;
    /// @notice Default escrow period (24 hours)
    uint32 public constant ESCROW_PERIOD = 86400;
    
    /// @notice Escrow settings
    /// @notice Default confirmation period for escrow (24 hours)
    uint32 public defaultEscrowDeadline;
    /// @notice Minimum time before cancel can be executed (1 hour)
    uint32 public minCancelTime;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the LaserGun contract
     * @notice Called once during contract deployment. Sets initial parameters and roles.
     * @param admin Address of the administrator who will receive all roles
     * @param _shieldFeePercent Fee percentage for shield operation (in basis points, 10000 = 100%)
     * @param _unshieldFeePercent Fee percentage for unshield operation (in basis points)
     * @param _transferFeePercent Fee percentage for transfer operation (in basis points)
     *
     * Requirements:
     * - All fee percentages must not exceed MAX_FEE_PERCENT (1000 = 10%)
     * - admin must be a valid address
     *
     * Effects:
     * - Sets all necessary roles for admin
     * - Configures initial fee percentages
     * - Initializes all parent contracts
     */
    function initialize(
        address admin,
        uint16 _shieldFeePercent,
        uint16 _unshieldFeePercent,
        uint16 _transferFeePercent
    ) public initializer {
        if (admin == address(0)) revert InvalidAdmin();
        if (_shieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_unshieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_transferFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();

        // Initialize parent contracts
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(FEE_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        // Set initial fees
        shieldFeePercent = _shieldFeePercent;
        unshieldFeePercent = _unshieldFeePercent;
        transferFeePercent = _transferFeePercent;

        // Set default escrow settings
        defaultEscrowDeadline = ESCROW_PERIOD;
        minCancelTime = MIN_CONFIRMATION_PERIOD;
    }

    /**
     * @notice Register a public key for encrypted secret delivery
     * @param publicKey The public key to register
     *
     * Requirements:
     * - publicKey must not be empty
     *
     * Effects:
     * - Stores the public key for the sender
     * - Emits PublicKeyRegistered event
     */
    function registerPublicKey(bytes calldata publicKey) external {
        if (publicKey.length == 0) revert EncryptedSecretCannotBeEmpty();
        
        publicKeys[msg.sender] = publicKey;
        emit PublicKeyRegistered(msg.sender, publicKey);
    }

    /**
     * @notice Create a shield for confidential token storage
     * @param amount Amount of tokens to deposit
     * @param token Address of the ERC20 token
     * @param commitment Unique commitment
     * @param bloomFilter Bloom filter for privacy
     *
     * Requirements:
     * - amount must be greater than 0
     * - token must be a valid address
     * - commitment must be unique
     * - contract must be paused
     *
     * Effects:
     * - Transfers tokens from user to contract
     * - Creates a new shield with the tokens
     * - Emits Shielded event
     */
    function shield(uint256 amount, address token, bytes32 commitment, bytes32 bloomFilter) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        // Validate operation limits
        Utils.validateOperationLimits(
            userOperationCount,
            userLastOperationTime,
            userLastOperationTimeByType,
            msg.sender,
            amount,
            true, // Creating a shield
            "shield",
            MAX_OPERATION_AMOUNT,
            OPERATION_COOLDOWN,
            MAX_SHIELDS_PER_USER,
            userShieldCount[msg.sender]
        );
        
        // Create shield using library
        uint256 fee = ShieldOperations.createShield(
            shields,
            userNonces,
            userShieldCount,
            msg.sender,
            amount,
            token,
            commitment,
            bloomFilter,
            shieldFeePercent,
            FEE_DENOMINATOR,
            MAX_SHIELDS_PER_USER,
            MIN_AMOUNT,
            MAX_OPERATION_AMOUNT,
            address(this)
        );
        
        // Collect fee
        if (fee > 0) {
            collectedFees[token] += fee;
            emit FeeCollected(token, fee);
        }
        
        emit Shielded(commitment, token, amount - fee, fee, bloomFilter);
    }

    /**
     * @notice Withdraw tokens from a shield
     * @param secret Shield secret
     * @param redeemAmount Amount of tokens to withdraw
     * @param recipient Address of the recipient
     * @param newCommitment New commitment for remaining balance
     *
     * Requirements:
     * - redeemAmount must be greater than 0
     * - recipient must be a valid address
     * - shield must exist and not be spent
     * - contract must not be paused
     *
     * Effects:
     * - Transfers tokens to recipient
     * - Marks shield as spent
     * - Creates new shield for remaining balance if applicable
     * - Emits Unshielded event
     */
    function unshield(bytes32 secret, uint256 redeemAmount, address recipient, bytes32 newCommitment)
        external
        nonReentrant
        whenNotPaused
    {
        // Generate commitment from secret with current user nonce
        bytes32 commitment;
        bool found = false;
        
        // Try with nonce values from current down to 1
        for (uint64 nonceTry = userNonces[msg.sender]; nonceTry > 0 && !found; nonceTry--) {
            commitment = keccak256(abi.encodePacked(
                secret, msg.sender, nonceTry, block.timestamp, block.prevrandao, address(this)
            ));
            
            if (shields[commitment].flags & 1 != 0) { // Check if exists
                found = true;
            }
        }
        
        // If not found with current nonce range, try with nonce = 0
        if (!found) {
            commitment = keccak256(abi.encodePacked(
                secret, msg.sender, uint64(0), block.timestamp, block.prevrandao, address(this)
            ));
        }
        
        // Validate operation limits
        Utils.validateOperationLimits(
            userOperationCount,
            userLastOperationTime,
            userLastOperationTimeByType,
            msg.sender,
            redeemAmount,
            false, // Not creating a shield
            "unshield",
            MAX_OPERATION_AMOUNT,
            OPERATION_COOLDOWN,
            MAX_SHIELDS_PER_USER,
            userShieldCount[msg.sender]
        );
        
        // Unshield using library
        (uint256 fee,) = ShieldOperations.unshield(
            shields,
            userNonces,
            msg.sender,
            commitment,
            redeemAmount,
            recipient,
            newCommitment,
            unshieldFeePercent,
            FEE_DENOMINATOR,
            MIN_AMOUNT,
            MAX_OPERATION_AMOUNT,
            address(this)
        );
        
        // Collect fee
        if (fee > 0) {
            collectedFees[shields[commitment].token] += fee;
            emit FeeCollected(shields[commitment].token, fee);
        }
        
        emit Unshielded(
            commitment,
            shields[commitment].token,
            redeemAmount,
            fee
        );
    }

    /**
     * @notice Private transfer of tokens between users
     * @param secret Secret of the sender's original shield
     * @param amount Amount of tokens to transfer
     * @param recipientCommitment Commitment for the recipient's shield
     * @param encryptedSecret Encrypted secret for the recipient
     * @param bloomFilter Bloom filter
     *
     * Requirements:
     * - amount must be greater than 0
     * - recipientCommitment must be unique
     * - sender's shield must exist and not be spent
     * - contract must not be paused
     *
     * Effects:
     * - Creates a new shield for the recipient
     * - Marks sender's shield as spent
     * - Creates new shield for remaining balance if applicable
     * - Emits SecretDelivered event
     */
    function transfer(
        bytes32 secret,
        uint256 amount,
        bytes32 recipientCommitment,
        bytes calldata encryptedSecret,
        bytes32 bloomFilter
    ) external nonReentrant whenNotPaused {
        // Validate encrypted secret
        if (encryptedSecret.length == 0) revert EncryptedSecretCannotBeEmpty();
        
        // Validate operation limits
        Utils.validateOperationLimits(
            userOperationCount,
            userLastOperationTime,
            userLastOperationTimeByType,
            msg.sender,
            amount,
            false, // Not creating a shield
            "transfer",
            MAX_OPERATION_AMOUNT,
            OPERATION_COOLDOWN,
            MAX_SHIELDS_PER_USER,
            userShieldCount[msg.sender]
        );
        
        // Calculate fee first
        // Generate commitment from secret with current user nonce
        bytes32 transferCommitment;
        bool found = false;
        
        // Try with nonce values from current down to 1
        for (uint64 nonceTry = userNonces[msg.sender]; nonceTry > 0 && !found; nonceTry--) {
            transferCommitment = keccak256(abi.encodePacked(
                secret, msg.sender, nonceTry, block.timestamp, block.prevrandao, address(this)
            ));
            
            if (shields[transferCommitment].flags & 1 != 0) { // Check if exists
                found = true;
            }
        }
        
        // If not found with current nonce range, try with nonce = 0
        if (!found) {
            transferCommitment = keccak256(abi.encodePacked(
                secret, msg.sender, uint64(0), block.timestamp, block.prevrandao, address(this)
            ));
        }
        uint256 fee = (amount * transferFeePercent) / FEE_DENOMINATOR;
        
        // Collect fee before transfer to avoid reentrancy issues
        if (fee > 0) {
            collectedFees[shields[transferCommitment].token] += fee;
            emit FeeCollected(shields[transferCommitment].token, fee);
        }
        
        // Transfer using library
        ShieldOperations.transfer(
            shields,
            userNonces,
            msg.sender,
            transferCommitment,
            amount,
            recipientCommitment,
            transferFeePercent,
            FEE_DENOMINATOR,
            MIN_AMOUNT,
            MAX_OPERATION_AMOUNT,
            address(this)
        );
        
        emit SecretDelivered(encryptedSecret, bloomFilter);
    }

    /**
     * @notice Consolidate multiple shields into one
     * @param secrets Array of shield secrets
     * @param newCommitment New commitment for the consolidated shield
     *
     * Requirements:
     * - secrets array must not be empty
     * - secrets array length must not exceed MAX_CONSOLIDATE_SHIELDS
     * - newCommitment must be unique
     * - all shields must exist and not be spent
     * - all shields must use the same token
     * - contract must not be paused
     *
     * Effects:
     * - Creates a new consolidated shield
     * - Marks all original shields as spent
     * - Emits ShieldConsolidated event
     */
    function consolidate(bytes32[] calldata secrets, bytes32 newCommitment)
        external
        nonReentrant
        whenNotPaused
    {
        // Validate operation limits
        uint256 totalAmount = 0;
        
        // Find all shields for consolidation using nonce = 0 (as originally designed)
        for (uint256 i = 0; i < secrets.length; i++) {
            // Generate commitment with nonce = 0 (same as when creating shield)
            bytes32 commitment = keccak256(abi.encodePacked(
                secrets[i], msg.sender, uint64(0), block.timestamp, block.prevrandao, address(this)
            ));
            
            totalAmount += shields[commitment].amount;
        }
        
        Utils.validateOperationLimits(
            userOperationCount,
            userLastOperationTime,
            userLastOperationTimeByType,
            msg.sender,
            totalAmount,
            false, // Not creating a shield
            "consolidate",
            MAX_OPERATION_AMOUNT,
            OPERATION_COOLDOWN,
            MAX_SHIELDS_PER_USER,
            userShieldCount[msg.sender]
        );
        
        // Consolidate using library with secrets array
        ShieldOperations.consolidate(
            shields,
            userNonces,
            msg.sender,
            secrets,
            newCommitment,
            MAX_CONSOLIDATE_SHIELDS,
            MIN_AMOUNT
        );
        
        emit ShieldConsolidated(secrets, newCommitment);
    }

    /**
     * @notice Set fee percentages
     * @param _shieldFeePercent Fee for shield operation
     * @param _unshieldFeePercent Fee for unshield operation
     * @param _transferFeePercent Fee for transfer operation
     *
     * Requirements:
     * - Caller must have FEE_MANAGER_ROLE
     * - All fee percentages must not exceed MAX_FEE_PERCENT
     *
     * Effects:
     * - Updates fee percentages
     * - Emits FeesUpdated event
     */
    function setFees(uint16 _shieldFeePercent, uint16 _unshieldFeePercent, uint16 _transferFeePercent) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
    {
        if (_shieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_unshieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_transferFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();

        shieldFeePercent = _shieldFeePercent;
        unshieldFeePercent = _unshieldFeePercent;
        transferFeePercent = _transferFeePercent;

        emit FeesUpdated(_shieldFeePercent, _unshieldFeePercent, _transferFeePercent);
    }

    /**
     * @notice Set escrow settings
     * @param _defaultEscrowDeadline Default confirmation period for escrow (in seconds)
     * @param _minCancelTime Minimum time before cancel can be executed (in seconds)
     *
     * Requirements:
     * - Caller must have ADMIN_ROLE
     * - _defaultEscrowDeadline must be between MIN_CONFIRMATION_PERIOD and MAX_CONFIRMATION_PERIOD
     * - _minCancelTime must be at least MIN_CONFIRMATION_PERIOD
     *
     * Effects:
     * - Updates escrow settings
     * - Emits EscrowSettingsUpdated event
     */
    function setEscrowSettings(uint32 _defaultEscrowDeadline, uint32 _minCancelTime) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (_defaultEscrowDeadline < MIN_CONFIRMATION_PERIOD || _defaultEscrowDeadline > MAX_CONFIRMATION_PERIOD) {
            revert InvalidConfirmationPeriod();
        }
        if (_minCancelTime < MIN_CONFIRMATION_PERIOD) {
            revert InvalidConfirmationPeriod();
        }

        defaultEscrowDeadline = _defaultEscrowDeadline;
        minCancelTime = _minCancelTime;

        emit EscrowSettingsUpdated(_defaultEscrowDeadline, _minCancelTime);
    }

    /**
     * @notice Withdraw accumulated fees
     * @param token Address of the token
     * @param recipient Address of the recipient
     *
     * Requirements:
     * - Caller must have FEE_MANAGER_ROLE
     * - There must be fees to withdraw
     *
     * Effects:
     * - Transfers fees to recipient
     * - Resets collected fees for the token
     * - Emits FeesWithdrawn event
     */
    function withdrawFees(address token, address recipient) external onlyRole(FEE_MANAGER_ROLE) {
        uint256 fees = collectedFees[token];
        if (fees == 0) revert NoFeesToWithdraw();

        collectedFees[token] = 0;
        
        bool success = IERC20(token).transfer(recipient, fees);
        if (!success) revert TransferFailed();
        
        emit FeesWithdrawn(token, recipient, fees);
    }

    /**
     * @notice Pause all contract operations
     *
     * Requirements:
     * - Caller must have PAUSER_ROLE
     *
     * Effects:
     * - Pauses the contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract operations
     *
     * Requirements:
     * - Caller must have PAUSER_ROLE
     *
     * Effects:
     * - Unpauses the contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of fees (only when paused)
     * @param token Address of the token
     * @param recipient Address of the recipient
     *
     * Requirements:
     * - Contract must be paused
     * - Caller must have ADMIN_ROLE
     *
     * Effects:
     * - Transfers all tokens of the specified type to recipient
     * - Emits EmergencyWithdraw event
     */
    function emergencyWithdraw(address token, address recipient) external onlyRole(ADMIN_ROLE) {
        if (!paused()) revert InvalidParameter();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NoFeesToWithdraw();

        bool success = IERC20(token).transfer(recipient, balance);
        if (!success) revert TransferFailed();
        
        emit EmergencyWithdraw(token, recipient, balance);
    }

    /**
     * @notice Mark an existing shield as escrow
     * @param commitment Commitment of the existing shield to mark as escrow
     * @param encryptedSecret Encrypted secret for the recipient
     * @param bloomFilter Bloom filter for privacy
     *
     * Requirements:
     * - commitment must exist and not be spent
     * - encryptedSecret must not be empty
     * - contract must not be paused
     *
     * Effects:
     * - Creates an escrow for the shield
     * - Marks shield as escrow
     * - Emits EscrowShielded event
     */
    function createEscrowShield(
        bytes32 commitment,
        bytes calldata encryptedSecret,
        bytes32 bloomFilter
    ) external nonReentrant whenNotPaused {
        if (encryptedSecret.length == 0) revert EncryptedSecretCannotBeEmpty();
        
        // Check if escrow already exists
        if (escrows[commitment].commitment == commitment) {
            revert CommitmentAlreadyExists();
        }
        
        // Create escrow using library
        uint256 fee = EscrowOperations.createEscrow(
            shields,
            escrows,
            userNonces,
            msg.sender,
            commitment,
            keccak256(abi.encodePacked("recipient")), // recipientCommitment - non-empty value
            uint32(block.timestamp) + defaultEscrowDeadline, // confirmationDeadline - set to future time
            defaultEscrowDeadline, 
            shieldFeePercent,
            FEE_DENOMINATOR
        );
        
        // Collect fee
        if (fee > 0) {
            collectedFees[shields[commitment].token] += fee;
            emit FeeCollected(shields[commitment].token, fee);
        }
        
        emit EscrowShielded(
            commitment,
            shields[commitment].token,
            shields[commitment].amount,
            bytes32(0), // senderCommitment
            bytes32(0), // recipientCommitment
            escrows[commitment].confirmationDeadline,
            fee,
            bloomFilter
        );
    }

    /**
     * @notice Create an escrow shield with specified parameters
     * @param amount Amount of tokens to escrow
     * @param token Address of the ERC20 token
     * @param commitment Commitment of the existing shield to mark as escrow
     * @param recipient Address of the recipient
     * @param confirmationDeadline Confirmation deadline for the escrow
     * @param bloomFilter Bloom filter for privacy
     *
     * Requirements:
     * - commitment must exist and not be spent
     * - encryptedSecret must not be empty
     * - contract must not be paused
     *
     * Effects:
     * - Creates an escrow for the shield
     * - Marks shield as escrow
     * - Emits EscrowShielded event
     */
    function createEscrowShield(
        uint256 amount,
        address token,
        bytes32 commitment,
        address recipient,
        uint32 confirmationDeadline,
        bytes32 bloomFilter
    ) external nonReentrant whenNotPaused {
        _validateEscrowShieldParams(amount, token, commitment, recipient);
        _validateEscrowShieldState(commitment);
        confirmationDeadline = _validateAndSetConfirmationDeadline(confirmationDeadline);
        uint256 fee = _calculateEscrowFee(amount);
        
        _createEscrowRecord(commitment, confirmationDeadline);
        _markShieldAsEscrow(commitment);
        _collectEscrowFee(token, fee);
        
        emit EscrowShielded(
            commitment,
            token,
            amount,
            bytes32(0), // senderCommitment
            bytes32(0), // recipientCommitment
            confirmationDeadline,
            fee,
            bloomFilter
        );
    }
    
    /**
     * @notice Validates basic parameters for escrow shield creation
     * @param amount Amount of tokens to escrow
     * @param token Address of the ERC20 token
     * @param commitment Commitment of the existing shield to mark as escrow
     * @param recipient Address of the recipient
     * @dev Reverts with appropriate error if any parameter is invalid
     */
    function _validateEscrowShieldParams(
        uint256 amount,
        address token,
        bytes32 commitment,
        address recipient
    ) private pure {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert EmptyToken();
        if (commitment == bytes32(0)) revert EmptyCommitment();
        if (recipient == address(0)) revert InvalidRecipient();
    }
    
    /**
     * @notice Validates shield state for escrow creation
     * @param commitment Commitment of the shield to validate
     * @dev Checks if shield exists, is not spent, and is not already an escrow
     */
    function _validateEscrowShieldState(bytes32 commitment) private view {
        ITypes.Shield storage escrowShield = shields[commitment];
        if (!ShieldFlags.getExists(escrowShield.flags)) revert ShieldDoesNotExist();
        if (ShieldFlags.getSpent(escrowShield.flags)) revert ShieldAlreadySpent();
        if (ShieldFlags.getIsEscrow(escrowShield.flags)) revert InvalidEscrowState();
    }
    
    /**
     * @notice Validates and sets confirmation deadline for escrow
     * @param confirmationDeadline Confirmation deadline for the escrow (0 to use default)
     * @return Validated confirmation deadline
     * @dev Sets to default if not provided, validates against current time and max period
     */
    function _validateAndSetConfirmationDeadline(uint32 confirmationDeadline)
        private
        view
        returns (uint32)
    {
        if (confirmationDeadline == 0) {
            confirmationDeadline = uint32(block.timestamp) + defaultEscrowDeadline;
        }
        if (confirmationDeadline <= block.timestamp) revert InvalidConfirmationPeriod();
        if (confirmationDeadline > block.timestamp + MAX_CONFIRMATION_PERIOD) revert InvalidConfirmationPeriod();
        
        return confirmationDeadline;
    }
    
    /**
     * @notice Calculates fee for escrow operation
     * @param amount Amount of tokens to calculate fee for
     * @return fee Calculated fee amount
     * @dev Uses shieldFeePercent and FEE_DENOMINATOR, validates net amount is positive
     */
    function _calculateEscrowFee(uint256 amount)
        private
        view
        returns (uint256 fee)
    {
        fee = (amount * shieldFeePercent) / FEE_DENOMINATOR;
        uint256 netAmount = amount - fee;
        if (netAmount == 0) revert NetAmountMustBePositive();
    }
    
    /**
     * @dev Creates the escrow record
     * @param commitment Commitment of the shield to create escrow for
     * @param confirmationDeadline Confirmation deadline for the escrow
     */
    function _createEscrowRecord(bytes32 commitment, uint32 confirmationDeadline) private {
        bytes32 prevrandaoValue = bytes32(block.prevrandao);
        if (prevrandaoValue == bytes32(0)) {
            prevrandaoValue = bytes32(0);
        }
        
        escrows[commitment] = ITypes.Escrow({
            commitment: commitment,
            timestamp: uint64(block.timestamp),
            confirmationDeadline: confirmationDeadline,
            creator: msg.sender,
            prevrandao: prevrandaoValue,
            creatorNonce: userNonces[msg.sender]
        });
    }
    
    /**
     * @notice Marks shield as escrow in storage
     * @param commitment Commitment of the shield to mark as escrow
     * @dev Sets the IS_ESCROW flag to true for the shield
     */
    function _markShieldAsEscrow(bytes32 commitment) private {
        ITypes.Shield storage escrowShield = shields[commitment];
        escrowShield.flags = ShieldFlags.setIsEscrow(escrowShield.flags, true);
    }
    
    /**
     * @notice Collects and records escrow fee
     * @param token Address of the token to collect fee for
     * @param fee Amount of fee to collect
     * @dev Adds fee to collectedFees mapping and emits FeeCollected event
     */
    function _collectEscrowFee(address token, uint256 fee) private {
        if (fee > 0) {
            collectedFees[token] += fee;
            emit FeeCollected(token, fee);
        }
    }

    /**
     * @notice Confirm an escrow and unshield funds to recipient
     * @param commitment Commitment of the escrow shield to confirm
     * @param senderSecret Secret of the sender who created the escrow
     * @param recipient Address of the recipient
     *
     * Requirements:
     * - commitment must be a valid escrow
     * - sender must be the escrow creator
     * - confirmation deadline must not have passed
     * - contract must not be paused
     *
     * Effects:
     * - Transfers funds to recipient
     * - Marks escrow as confirmed
     * - Emits EscrowConfirmed and EscrowReleased events
     */
    function confirmEscrow(bytes32 commitment, bytes32 senderSecret, address recipient) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        // Confirm escrow using library
        (uint256 fee, uint256 netAmount) = EscrowOperations.confirmEscrow(
            shields,
            escrows,
            userNonces,
            msg.sender,
            commitment,
            senderSecret,
            recipient,
            keccak256(abi.encodePacked("recipient")), // recipientCommitment - non-empty value
            shieldFeePercent,
            FEE_DENOMINATOR,
            address(this)
        );
        
        // Collect fee
        if (fee > 0) {
            collectedFees[shields[commitment].token] += fee;
            emit FeeCollected(shields[commitment].token, fee);
        }
        
        emit EscrowConfirmed(commitment, bytes32(0)); // senderCommitment
        emit EscrowReleased(commitment, bytes32(0), netAmount); // recipientCommitment, amount
    }

    /**
     * @notice Cancel an escrow and unshield funds back to sender
     * @param commitment Commitment of the escrow shield to cancel
     * @param senderSecret Secret of the sender who created the escrow
     *
     * Requirements:
     * - commitment must be a valid escrow
     * - sender must be the escrow creator
     * - minimum cancel time must have passed
     * - contract must not be paused
     *
     * Effects:
     * - Returns funds to sender
     * - Marks escrow as cancelled
     * - Emits EscrowCancelled event
     */
    function cancelEscrow(bytes32 commitment, bytes32 senderSecret) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        // Cancel escrow using library
        (uint256 fee, uint256 netAmount) = EscrowOperations.cancelEscrow(
            shields,
            escrows,
            userNonces,
            msg.sender,
            commitment,
            senderSecret,
            minCancelTime,
            shieldFeePercent,
            FEE_DENOMINATOR,
            address(this)
        );
        
        // Collect fee
        if (fee > 0) {
            collectedFees[shields[commitment].token] += fee;
            emit FeeCollected(shields[commitment].token, fee);
        }
        
        emit EscrowCancelled(commitment, bytes32(0), netAmount); // senderCommitment, amount
    }

    // View functions

    /**
     * @notice Get shield information
     * @param commitment Shield commitment
     * @return exists Flag indicating if shield exists
     * @return token Address of the token
     * @return amount Amount of tokens
     * @return timestamp Creation time
     * @return spent Flag indicating if shield is spent
     */
    function getShieldInfo(bytes32 commitment)
        external
        view
        returns (bool exists, address token, uint256 amount, uint256 timestamp, bool spent)
    {
        ITypes.Shield storage shieldInfo = shields[commitment];
        exists = ShieldFlags.getExists(shieldInfo.flags);
        token = shieldInfo.token;
        amount = shieldInfo.amount;
        timestamp = shieldInfo.timestamp;
        spent = ShieldFlags.getSpent(shieldInfo.flags);
    }

    /**
     * @notice Generate commitment from secret and address with additional entropy
     * @dev Uses block timestamp, prevrandao, contract address and user nonce for additional entropy
     * @param secret Secret value
     * @param recipient Address of the recipient
     * @return Commitment hash
     */
    function generateCommitment(bytes32 secret, address recipient) external view returns (bytes32) {
        return Utils.generateCommitment(secret, recipient, 0, address(this));
    }

    /**
     * @notice Get shield balance
     * @param secret Shield secret
     * @param token Address of the token
     * @return Shield balance
     */
    function getShieldBalance(bytes32 secret, address token) external view returns (uint256) {
        return Utils.getShieldBalance(shields, secret, token, msg.sender, address(this));
    }

    /**
     * @notice Check if commitment is active
     * @param commitment Commitment to check
     * @return true if shield is active
     */
    function isCommitmentActive(bytes32 commitment) external view returns (bool) {
        return Utils.isCommitmentActive(shields, commitment);
    }

    /**
     * @notice Get escrow information
     * @param commitment Escrow commitment
     * @return escrowData Complete escrow data
     * @return shieldData Associated shield data
     */
    function getEscrowInfo(bytes32 commitment)
        external
        view
        returns (ITypes.Escrow memory escrowData, ITypes.Shield memory shieldData)
    {
        (escrowData, shieldData) =
            EscrowOperations.getEscrowInfo(shields, escrows, commitment);
    }

    /**
     * @notice Check if commitment is an active escrow
     * @param commitment Commitment to check
     * @return true if commitment is an active escrow
     */
    function isActiveEscrow(bytes32 commitment) external view returns (bool) {
        return EscrowOperations.isActiveEscrow(shields, escrows, commitment);
    }

    /**
     * @notice Check if commitment is an active escrow for a specific user
     * @param commitment Commitment to check
     * @param user Address of the user to verify ownership
     * @return true if commitment is an active escrow owned by the user
     */
    function isActiveEscrowForUser(bytes32 commitment, address user) external view returns (bool) {
        return EscrowOperations.isActiveEscrowForUser(shields, escrows, commitment, user);
    }

    /**
     * @notice Get escrow status
     * @param commitment Escrow commitment
     * @return status Current status of the escrow (Pending, Confirmed, Cancelled, Expired)
     */
    function getEscrowStatus(bytes32 commitment) external view returns (string memory status) {
        return EscrowOperations.getEscrowStatus(shields, escrows, commitment);
    }

    /**
     * @notice Get escrow shield information
     * @param commitment Escrow commitment
     * @return exists Flag indicating if escrow exists
     * @return token Address of the token
     * @return amount Amount of tokens
     * @return timestamp Creation time
     * @return spent Flag indicating if shield is spent
     * @return confirmationDeadline Timestamp until when sender must confirm
     * @return creator Address of the escrow creator
     */
    function getEscrowShieldInfo(bytes32 commitment)
        external
        view
        returns (
            bool exists,
            address token,
            uint256 amount,
            uint256 timestamp,
            bool spent,
            uint256 confirmationDeadline,
            address creator
        )
    {
        (ITypes.Escrow memory escrowData, ITypes.Shield memory shieldData) =
            EscrowOperations.getEscrowInfo(shields, escrows, commitment);
        
        exists = escrowData.commitment != bytes32(0);
        token = shieldData.token;
        amount = shieldData.amount;
        timestamp = shieldData.timestamp;
        spent = ShieldFlags.getSpent(shieldData.flags);
        confirmationDeadline = escrowData.confirmationDeadline;
        creator = escrowData.creator;
    }

    /**
     * @notice Release funds from an expired escrow to sender
     * @param commitment Commitment of the escrow shield to release
     * @param senderSecret Secret of the sender who created the escrow
     *
     * Requirements:
     * - commitment must be a valid escrow
     * - confirmation deadline must have passed
     * - contract must not be paused
     *
     * Effects:
     * - Transfers funds back to sender
     * - Marks escrow as released
     * - Emits EscrowReleased event
     */
    function releaseEscrow(bytes32 commitment, bytes32 senderSecret)
        external
        nonReentrant
        whenNotPaused
    {
        // Check if escrow exists
        ITypes.Escrow storage escrow = escrows[commitment];
        if (escrow.commitment != commitment) {
            revert InvalidEscrowState();
        }
        
        // Release expired escrow using library
        (uint256 fee, uint256 netAmount) = EscrowOperations.releaseExpiredEscrow(
            shields,
            escrows,
            userNonces,
            msg.sender,
            commitment,
            senderSecret,
            shieldFeePercent,
            FEE_DENOMINATOR
        );
        
        // Collect fee
        if (fee > 0) {
            collectedFees[shields[commitment].token] += fee;
            emit FeeCollected(shields[commitment].token, fee);
        }
        
        emit EscrowReleased(commitment, bytes32(0), netAmount); // recipientCommitment, amount
    }

    /**
     * @dev Function required by UUPS upgradeable pattern
     */
    function _authorizeUpgrade(address /* newImplementation */) internal view override onlyRole(UPGRADER_ROLE) {
        // Authorization is handled by onlyRole modifier
        // No additional implementation needed
        return;
    }
}