// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ILaserGun {
    // Events
    event VoucherCreated(bytes32 indexed commitment, address indexed token, uint256 amount, uint256 fee);
    event VoucherRedeemed(bytes32 indexed commitment, address indexed token, uint256 amount, uint256 fee);
    event VoucherConsolidated(bytes32[] indexed oldCommitments, bytes32 indexed newCommitment);
    event FeesUpdated(uint256 shieldFee, uint256 unshieldFee);
    event FeeCollected(address indexed token, uint256 amount);
    event SecretDelivered(bytes encryptedSecret);

    // Custom Errors
    error FeeExceedsMaximum();
    error CommitmentAlreadyExists();
    error NetAmountMustBePositive();
    error VoucherDoesNotExist();
    error VoucherAlreadySpent();
    error InsufficientVoucherBalance();
    error NewCommitmentRequiredForRemainingBalance();
    error InvalidRecipient();
    error RecipientCommitmentAlreadyExists();
    error NoSecretsProvided();
    error TooManyVouchersToConsolidate();
    error TotalAmountMustBePositive();
    error AllVouchersMustUseSameToken();
    error AmountOverflow();
    error InvalidToken();
    error NoFeesToWithdraw();
    error AmountTooSmall();
    error EncryptedSecretCannotBeEmpty();
    error ExpectedPause();
    error EmptyCommitment();

    // Structs
    struct Voucher {
        address token;
        uint256 amount;
        uint256 timestamp;
        bool exists;
        bool spent;
    }

    // Core functions
    function deposit(uint256 amount, address token, bytes32 commitment) external;

    function redeem(bytes32 secret, uint256 redeemAmount, address recipient, bytes32 newCommitment) external;

    function transfer(
        bytes32 secret,
        uint256 amount,
        bytes32 recipientCommitment,
        bytes calldata encryptedSecret
    ) external;

    function consolidate(bytes32[] calldata secrets, bytes32 newCommitment) external;

    // View functions
    function getVoucherInfo(
        bytes32 commitment
    ) external view returns (bool exists, address token, uint256 amount, uint256 timestamp, bool spent);

    function generateCommitment(bytes32 secret, address recipient) external pure returns (bytes32);

    function getMyVoucherBalance(bytes32 secret, address token) external view returns (uint256);

    function isCommitmentActive(bytes32 commitment) external view returns (bool);

    // Admin functions
    function setFees(uint256 _shieldFeePercent, uint256 _unshieldFeePercent) external;

    function withdrawFees(address token, address recipient) external;

    function pause() external;

    function unpause() external;

    function emergencyWithdraw(address token, address recipient) external;
}
