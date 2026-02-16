// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ITypes
} from "./ITypes.sol";

/**
 * @title ILaserGun
 * @author LaserGun Team
 * @notice Interface for the LaserGun contract providing confidential transactions using commitments
 * @dev Defines all functions, events and errors needed to work with private token shields
 *
 * Key operations:
 * - Shield: deposit tokens into a private shield
 * - Unshield: withdraw tokens from a shield
 * - Transfer: private transfer between users
 * - Consolidate: merge multiple shields
 *
 * Features:
 * - Uses commitments to ensure privacy
 * - Supports operation fees
 * - Includes pause mechanism for emergency situations
 */
interface ILaserGun {
    // Events

    /**
     * @notice Event emitted when a new shield is created
     * @param commitment Unique identifier of the shield
     * @param token Address of the token
     * @param amount Amount of tokens in the shield
     * @param fee Operation fee
     * @param bloomFilter Bloom filter for privacy
     */
    event Shielded(
        bytes32 indexed commitment,
        address indexed token,
        uint256 amount,
        uint256 fee,
        bytes32 indexed bloomFilter
    );

    /**
     * @notice Event emitted when tokens are withdrawn from a shield
     * @param commitment Identifier of the shield
     * @param token Address of the token
     * @param amount Amount of tokens withdrawn
     * @param fee Operation fee
     */
    event Unshielded(bytes32 indexed commitment, address indexed token, uint256 amount, uint256 fee);

    /**
     * @notice Event emitted when shields are consolidated
     * @param oldCommitments Array of identifiers of the original shields
     * @param newCommitment Identifier of the new consolidated shield
     */
    event ShieldConsolidated(bytes32[] indexed oldCommitments, bytes32 indexed newCommitment);

    /**
     * @notice Event emitted when fees are updated
     * @param shieldFee New fee for shield
     * @param unshieldFee New fee for unshield
     * @param transferFee New fee for transfer
     */
    event FeesUpdated(uint256 shieldFee, uint256 unshieldFee, uint256 transferFee);

    /**
     * @notice Event emitted when a fee is collected
     * @param token Address of the token
     * @param amount Amount of fee collected
     */
    event FeeCollected(address indexed token, uint256 amount);

    /**
     * @notice Event emitted when an encrypted secret is delivered
     * @param encryptedSecret Encrypted secret
     * @param bloomFilter Bloom filter
     */
    event SecretDelivered(bytes encryptedSecret, bytes32 indexed bloomFilter);

    /**
     * @notice Event emitted when an emergency withdrawal occurs
     * @param token Address of the token
     * @param recipient Address of the recipient
     * @param amount Withdrawal amount
     */
    event EmergencyWithdraw(address indexed token, address indexed recipient, uint256 amount);

    /**
     * @notice Event emitted when an escrow shield is created
     * @param commitment Unique identifier of the escrow shield
     * @param token Address of the token
     * @param amount Amount of tokens in the escrow
     * @param senderCommitment Commitment of the sender
     * @param recipientCommitment Commitment of the recipient
     * @param confirmationDeadline Timestamp until when sender must confirm
     * @param fee Operation fee
     * @param bloomFilter Bloom filter for privacy
     */
    event EscrowShielded(
        bytes32 indexed commitment,
        address indexed token,
        uint256 amount,
        bytes32 indexed senderCommitment,
        bytes32 recipientCommitment,
        uint256 confirmationDeadline,
        uint256 fee,
        bytes32 bloomFilter
    );

    /**
     * @notice Event emitted when an escrow is confirmed by sender
     * @param commitment Identifier of the escrow shield
     * @param senderCommitment Commitment of the sender who confirmed
     */
    event EscrowConfirmed(bytes32 indexed commitment, bytes32 indexed senderCommitment);

    /**
     * @notice Event emitted when escrow funds are released to recipient
     * @param commitment Identifier of the escrow shield
     * @param recipientCommitment Commitment of the recipient
     * @param amount Amount of tokens released
     */
    event EscrowReleased(bytes32 indexed commitment, bytes32 indexed recipientCommitment, uint256 amount);

    /**
     * @notice Event emitted when an escrow is cancelled
     * @param commitment Identifier of the escrow shield
     * @param senderCommitment Commitment of the sender who cancelled
     * @param amount Amount of tokens returned
     */
    event EscrowCancelled(bytes32 indexed commitment, bytes32 indexed senderCommitment, uint256 amount);

    /**
     * @notice Event emitted when an escrow expires
     * @param commitment Identifier of the escrow shield
     * @param senderCommitment Commitment of the sender
     * @param amount Amount of tokens that can be refunded
     */
    event EscrowExpired(bytes32 indexed commitment, bytes32 indexed senderCommitment, uint256 amount);

    /**
     * @notice Event emitted when escrow settings are updated
     * @param defaultEscrowDeadline New default confirmation period
     * @param minCancelTime New minimum cancel time
     */
    event EscrowSettingsUpdated(uint32 defaultEscrowDeadline, uint32 minCancelTime);

    /**
     * @notice Event emitted when access to an escrow is attempted
     * @param commitment Identifier of the escrow shield
     * @param user Address of the user attempting access
     * @param action Type of action attempted (confirm, cancel, release)
     */
    event EscrowAccessAttempted(bytes32 indexed commitment, address indexed user, string action);

    /**
     * @notice Event emitted when a role is granted to an account
     * @param role The role that was granted
     * @param account The account that received the role
     * @param sender The account that granted the role
     */
    // event RoleGranted(
    //     bytes32 indexed role,
    //     address indexed account,
    //     address indexed sender
    // ); // Removed as already defined in AccessControlUpgradeable

    /**
     * @notice Event emitted when a role is revoked from an account
     * @param role The role that was revoked
     * @param account The account that had the role revoked
     * @param sender The account that revoked the role
     */
    // event RoleRevoked(
    //     bytes32 indexed role,
    //     address indexed account,
    //     address indexed sender
    // ); // Removed as already defined in AccessControlUpgradeable

    /**
     * @notice Event emitted when the contract is paused
     * @param account The account that paused the contract
     */
    // event Paused(address account); // Removed as already defined in PausableUpgradeable

    /**
     * @notice Event emitted when the contract is unpaused
     * @param account The account that unpaused the contract
     */
    // event Unpaused(address account); // Removed as already defined in PausableUpgradeable

    /**
     * @notice Event emitted when fees are withdrawn
     * @param token Address of the token
     * @param recipient Address of the recipient
     * @param amount Amount of fees withdrawn
     */
    event FeesWithdrawn(address indexed token, address indexed recipient, uint256 amount);


    /**
     * @notice Event emitted when a public key is registered
     * @param account Address of the account that registered the key
     * @param publicKey The registered public key
     */
    event PublicKeyRegistered(address indexed account, bytes publicKey);

    /**
     * @notice Event emitted when a token transfer is executed
     * @param token Address of the token
     * @param from Address of the sender
     * @param to Address of the recipient
     * @param amount Amount of tokens transferred
     */
    event TokenTransferExecuted(address indexed token, address indexed from, address indexed to, uint256 amount);

    /**
     * @notice Event emitted when operation limits are validated
     * @param user Address of the user
     * @param operationType Type of operation
     * @param operationCount New operation count
     */
    event OperationLimitsValidated(address indexed user, string operationType, uint256 operationCount);

    /**
     * @notice Event emitted when a shield is created internally
     * @param commitment Commitment of the shield
     * @param token Address of the token
     * @param amount Amount of tokens
     */
    event ShieldCreated(bytes32 indexed commitment, address indexed token, uint256 amount);

    // Custom Errors

    /**
     * @dev Error thrown when admin address is invalid
     */
    error InvalidAdmin();

    /**
     * @dev Error thrown when fee exceeds maximum allowed percentage
     */
    error FeeExceedsMaximum();

    /**
     * @dev Error thrown when commitment already exists
     */
    error CommitmentAlreadyExists();

    /**
     * @dev Error thrown when net amount after fee is zero or negative
     */
    error NetAmountMustBePositive();

    /**
     * @dev Error thrown when shield does not exist
     */
    error ShieldDoesNotExist();

    /**
     * @dev Error thrown when shield has already been spent
     */
    error ShieldAlreadySpent();

    /**
     * @dev Error thrown when shield balance is insufficient
     */
    error InsufficientShieldBalance();

    /**
     * @dev Error thrown when new commitment is required for remaining balance
     */
    error NewCommitmentRequiredForRemainingBalance();

    /**
     * @dev Error thrown when recipient address is invalid
     */
    error InvalidRecipient();

    /**
     * @dev Error thrown when recipient commitment already exists
     */
    error RecipientCommitmentAlreadyExists();

    /**
     * @dev Error thrown when no secrets are provided for consolidation
     */
    error NoSecretsProvided();

    /**
     * @dev Error thrown when too many shields are provided for consolidation
     */
    error TooManyShieldsToConsolidate();

    /**
     * @dev Error thrown when total amount is zero
     */
    error TotalAmountMustBePositive();

    /**
     * @dev Error thrown when shields use different tokens
     */
    error AllShieldsMustUseSameToken();

    /**
     * @dev Error thrown when amount would cause overflow
     */
    error AmountOverflow();

    /**
     * @dev Error thrown when token address is invalid
     */
    error InvalidToken();

    /**
     * @dev Error thrown when there are no fees to withdraw
     */
    error NoFeesToWithdraw();

    /**
     * @dev Error thrown when amount is too small
     */
    error AmountTooSmall();

    /**
     * @dev Error thrown when encrypted secret is empty
     */
    error EncryptedSecretCannotBeEmpty();

    /**
     * @dev Error thrown when commitment is empty
     */
    error EmptyCommitment();

    /**
     * @dev Error thrown when amount is zero
     */
    error ZeroAmount();

    /**
     * @dev Error thrown when token address is empty
     */
    error EmptyToken();

    /**
     * @dev Error thrown when commitment is invalid
     */
    error InvalidCommitment();

    /**
     * @dev Error thrown when trying to unshield an escrow shield directly
     */
    error CannotUnshieldEscrowDirectly();

    /**
     * @dev Error thrown when trying to transfer an escrow shield directly
     */
    error CannotTransferEscrowDirectly();

    /**
     * @dev Error thrown when escrow is not in the expected state
     */
    error InvalidEscrowState();

    /**
     * @dev Error thrown when caller is not the escrow sender
     */
    error NotEscrowSender();

    /**
     * @dev Error thrown when caller is not the escrow recipient
     */
    error NotEscrowRecipient();

    /**
     * @dev Error thrown when confirmation period is invalid
     */
    error InvalidConfirmationPeriod();

    /**
     * @dev Error thrown when escrow confirmation deadline has passed
     */
    error ConfirmationDeadlinePassed();

    /**
     * @dev Error thrown when escrow is not yet confirmed
     */
    error EscrowNotConfirmed();

    /**
     * @dev Error thrown when escrow is already confirmed
     */
    error EscrowAlreadyConfirmed();

    /**
     * @dev Error thrown when escrow is already released
     */
    error EscrowAlreadyReleased();

    /**
     * @dev Error thrown when escrow is already cancelled
     */
    error EscrowAlreadyCancelled();

    /**
     * @dev Error thrown when user has insufficient token balance
     */
    error InsufficientTokenBalance();

    /**
     * @dev Error thrown when contract has insufficient token balance
     */
    error InsufficientContractBalance();

    /**
     * @dev Error thrown when token transfer fails
     */
    error TransferFailed();

    /**
     * @dev Error thrown when operation amount exceeds maximum limit
     */
    error AmountTooLarge();

    /**
     * @dev Error thrown when operations are too frequent (spam protection)
     */
    error OperationTooFrequent();

    /**
     * @dev Error thrown when user has too many shields
     */
    error TooManyShields();

    /**
     * @dev Error thrown when a parameter is invalid
     */
    error InvalidParameter();

    // Core functions

    /**
     * @notice Create a shield for confidential token storage
     * @param amount Amount of tokens to deposit
     * @param token Address of the ERC20 token
     * @param commitment Unique commitment
     * @param bloomFilter Bloom filter for privacy
     */
    function shield(uint256 amount, address token, bytes32 commitment, bytes32 bloomFilter) external;

    /**
     * @notice Withdraw tokens from a shield
     * @param secret Shield secret
     * @param redeemAmount Amount of tokens to withdraw
     * @param recipient Address of the recipient
     * @param newCommitment New commitment for remaining balance
     */
    function unshield(bytes32 secret, uint256 redeemAmount, address recipient, bytes32 newCommitment) external;

    /**
     * @notice Private transfer of tokens between users
     * @param secret Secret of the sender's original shield
     * @param amount Amount of tokens to transfer
     * @param recipientCommitment Commitment for the recipient's shield
     * @param encryptedSecret Encrypted secret for the recipient
     * @param bloomFilter Bloom filter
     */
    function transfer(
        bytes32 secret,
        uint256 amount,
        bytes32 recipientCommitment,
        bytes calldata encryptedSecret,
        bytes32 bloomFilter
    ) external;

    /**
     * @notice Consolidate multiple shields into one
     * @param secrets Array of shield secrets
     * @param newCommitment New commitment for the consolidated shield
     */
    function consolidate(bytes32[] calldata secrets, bytes32 newCommitment) external;

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
    function getShieldInfo(
        bytes32 commitment
    ) external view returns (bool exists, address token, uint256 amount, uint256 timestamp, bool spent);

    /**
     * @notice Generate commitment from secret and address with additional entropy
     * @dev Uses block timestamp, prevrandao, contract address and user nonce for additional entropy
     * @param secret Secret value
     * @param recipient Address of the recipient
     * @return Commitment hash
     */
    function generateCommitment(bytes32 secret, address recipient) external view returns (bytes32);

    /**
     * @notice Get shield balance
     * @param secret Shield secret
     * @param token Address of the token
     * @return Shield balance
     */
    function getShieldBalance(bytes32 secret, address token) external view returns (uint256);

    /**
     * @notice Check if commitment is active
     * @param commitment Commitment to check
     * @return true if shield is active
     */
    function isCommitmentActive(bytes32 commitment) external view returns (bool);

    // Admin functions

    /**
     * @notice Set fee percentages
     * @param _shieldFeePercent Fee for shield operation
     * @param _unshieldFeePercent Fee for unshield operation
     * @param _transferFeePercent Fee for transfer operation
     */
    function setFees(uint16 _shieldFeePercent, uint16 _unshieldFeePercent, uint16 _transferFeePercent) external;

    /**
     * @notice Set escrow settings
     * @param _defaultEscrowDeadline Default confirmation period for escrow (in seconds)
     * @param _minCancelTime Minimum time before cancel can be executed (in seconds)
     */
    function setEscrowSettings(uint32 _defaultEscrowDeadline, uint32 _minCancelTime) external;

    /**
     * @notice Withdraw accumulated fees
     * @param token Address of the token
     * @param recipient Address of the recipient
     */
    function withdrawFees(address token, address recipient) external;

    /**
     * @notice Pause all contract operations
     */
    function pause() external;

    /**
     * @notice Unpause contract operations
     */
    function unpause() external;

    /**
     * @notice Emergency withdrawal of fees (only when paused)
     * @param token Address of the token
     * @param recipient Address of the recipient
     */
    function emergencyWithdraw(address token, address recipient) external;

    // Escrow functions

    /**
     * @notice Mark an existing shield as escrow
     * @param commitment Commitment of the existing shield to mark as escrow
     * @param encryptedSecret Encrypted secret for the recipient
     * @param bloomFilter Bloom filter for privacy
     */
    function createEscrowShield(
        bytes32 commitment,
        bytes calldata encryptedSecret,
        bytes32 bloomFilter
    ) external;

    /**
     * @notice Confirm an escrow and unshield funds to recipient
     * @param commitment Commitment of the escrow shield to confirm
     * @param senderSecret Secret of the sender who created the escrow
     * @param recipient Address of the recipient
     */
    function confirmEscrow(bytes32 commitment, bytes32 senderSecret, address recipient) external;

    /**
     * @notice Cancel an escrow and unshield funds back to sender
     * @param commitment Commitment of the escrow shield to cancel
     * @param senderSecret Secret of the sender who created the escrow
     */
    function cancelEscrow(bytes32 commitment, bytes32 senderSecret) external;

    /**
     * @notice Release funds from an expired escrow to sender
     * @param commitment Commitment of the escrow shield to release
     * @param senderSecret Secret of the sender who created the escrow
     */
    function releaseEscrow(bytes32 commitment, bytes32 senderSecret) external;

    // Escrow view functions

    /**
     * @notice Get escrow information
     * @param commitment Escrow commitment
     * @return escrow Complete escrow data
     * @return shield Associated shield data
     */
    function getEscrowInfo(bytes32 commitment)
        external
        view
        returns (ITypes.Escrow memory escrow, ITypes.Shield memory shield);

    /**
     * @notice Check if commitment is an active escrow
     * @param commitment Commitment to check
     * @return true if commitment is an active escrow
     */
    function isActiveEscrow(bytes32 commitment) external view returns (bool);

    /**
     * @notice Check if commitment is an active escrow for a specific user
     * @param commitment Commitment to check
     * @param user Address of the user to verify ownership
     * @return true if commitment is an active escrow owned by the user
     */
    function isActiveEscrowForUser(bytes32 commitment, address user) external view returns (bool);

    /**
     * @notice Get escrow status
     * @param commitment Escrow commitment
     * @return status Current status of the escrow (Pending, Confirmed, Cancelled, Expired)
     */
    function getEscrowStatus(bytes32 commitment) external view returns (string memory status);

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
        );
}