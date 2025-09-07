// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ILaserGun} from "./interfaces/ILaserGun.sol";

contract LaserGun is
    Initializable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ILaserGun
{
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // State variables
    mapping(bytes32 => Shield) public shields;

    // User nonces for deterministic commitment generation
    mapping(address => uint256) public userNonces;

    // Public keys for encrypted secret delivery
    mapping(address => bytes) public publicKeys;

    // Fee settings
    uint256 public shieldFeePercent; // Fee percentage in basis points (25 = 0.25%)
    uint256 public unshieldFeePercent; // Fee percentage in basis points
    uint256 public transferFeePercent; // Fee percentage in basis points

    mapping(address => uint256) public collectedFees; // Token => accumulated fees

    // Constants
    uint256 public constant MAX_FEE_PERCENT = 1000; // 10% maximum fee
    uint256 public constant FEE_DENOMINATOR = 10000; // 100% = 10000 basis points
    uint256 public constant MAX_CONSOLIDATE_SHIELDS = 10; // Maximum Shields in consolidate
    uint256 public constant MIN_AMOUNT = 1; // Minimum amount (1 wei) to prevent dust attacks

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        uint256 _shieldFeePercent,
        uint256 _unshieldFeePercent,
        uint256 _transferFeePercent
    ) public initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();

        if (_shieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_unshieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_transferFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(FEE_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        shieldFeePercent = _shieldFeePercent;
        unshieldFeePercent = _unshieldFeePercent;
        transferFeePercent = _transferFeePercent;
    }

    // Public key registration
    function registerPublicKey(bytes calldata publicKey) external {
        publicKeys[msg.sender] = publicKey;
    }

    // Create Shield by depositing tokens (Shield operation)
    function shield(uint256 amount, address token, bytes32 commitment) external nonReentrant whenNotPaused {
        validateShieldParams(amount, token, commitment);
        if (shields[commitment].exists) revert CommitmentAlreadyExists();

        // Calculate fee using library
        uint256 fee = calculateFee(amount, shieldFeePercent);
        uint256 netAmount = amount - fee;
        if (netAmount == 0) revert NetAmountMustBePositive();

        // Transfer tokens from sender (including fee)
        IERC20Upgradeable(token).transferFrom(msg.sender, address(this), amount);

        // Track collected fees
        collectedFees[token] += fee;

        // Create Shield with net amount
        shields[commitment] = Shield({
            token: token,
            amount: netAmount,
            timestamp: block.timestamp,
            exists: true,
            spent: false
        });

        emit Shielded(commitment, token, netAmount, fee);
        if (fee > 0) {
            emit FeeCollected(token, fee);
        }
    }

    // Redeem Shield with recipient-bound commitment to third party(Unshield operation)
    function unshield(
        bytes32 secret,
        uint256 redeemAmount,
        address recipient,
        bytes32 newCommitment // For remaining balance (0x0 if no remaining balance)
    ) external nonReentrant whenNotPaused {
        if (redeemAmount < MIN_AMOUNT) revert AmountTooSmall();
        if (recipient == address(0)) revert InvalidRecipient();

        bytes32 commitment = this.generateCommitment(secret, msg.sender);
        Shield storage currentShield = shields[commitment];
        if (!currentShield.exists) revert ShieldDoesNotExist();
        if (currentShield.spent) revert ShieldAlreadySpent();
        if (redeemAmount > currentShield.amount) revert InsufficientShieldBalance();

        // Calculate fee using library
        uint256 fee = calculateFee(redeemAmount, unshieldFeePercent);
        uint256 netRedeemAmount = redeemAmount - fee;
        uint256 remainingAmount = currentShield.amount - redeemAmount;

        // Mark current Shield as spent
        currentShield.spent = true;

        // Track collected fees
        collectedFees[currentShield.token] += fee;

        // Send net redeemed amount to recipient
        if (netRedeemAmount > 0) {
            IERC20Upgradeable(currentShield.token).transfer(recipient, netRedeemAmount);
        }

        // Create new Shield for remaining balance if needed
        if (remainingAmount > 0) {
            if (newCommitment == bytes32(0)) revert NewCommitmentRequiredForRemainingBalance();
            if (shields[newCommitment].exists) revert CommitmentAlreadyExists();

            shields[newCommitment] = Shield({
                token: currentShield.token,
                amount: remainingAmount,
                timestamp: block.timestamp,
                exists: true,
                spent: false
            });

            emit Shielded(newCommitment, currentShield.token, remainingAmount, 0);
        }

        emit Unshielded(commitment, currentShield.token, netRedeemAmount, fee);
        if (fee > 0) {
            emit FeeCollected(currentShield.token, fee);
        }
    }

    // Create Shield for specific recipient (for transfers)
    function transfer(
        bytes32 secret,
        uint256 amount,
        bytes32 recipientCommitment,
        bytes calldata encryptedSecret
    ) external nonReentrant whenNotPaused {
        if (amount < MIN_AMOUNT) revert AmountTooSmall();
        if (encryptedSecret.length == 0) revert EncryptedSecretCannotBeEmpty();

        bytes32 senderCommitment = this.generateCommitment(secret, msg.sender);

        Shield storage senderShield = shields[senderCommitment];
        if (!senderShield.exists) revert ShieldDoesNotExist();
        if (senderShield.spent) revert ShieldAlreadySpent();
        if (amount > senderShield.amount) revert InsufficientShieldBalance();
        if (shields[recipientCommitment].exists) revert RecipientCommitmentAlreadyExists();

        // Calculate the transfer fee
        uint256 transferFee = (amount * transferFeePercent) / FEE_DENOMINATOR;

        // Check if the transfer fee exceeds the maximum allowed fee
        if (transferFee > MAX_FEE) revert FeeExceedsMaximum();

        // Calculate the net amount to be transferred (amount - transfer fee)
        uint256 netAmount = amount - transferFee;

        // Mark sender's Shield as spent first (reentrancy protection)
        senderShield.spent = true;

        // Create Shield for recipient
        shields[recipientCommitment] = Shield({
            token: senderShield.token,
            amount: netAmount, // Transfer the net amount to the recipient
            timestamp: block.timestamp,
            exists: true,
            spent: false
        });

        // Create new Shield for sender's remaining balance if any
        uint256 remainingAmount = senderShield.amount - amount;
        if (remainingAmount > 0) {
            uint256 nonce = userNonces[msg.sender]++;
            bytes32 senderNewCommitment = generateSenderCommitment(msg.sender, nonce);

            shields[senderNewCommitment] = Shield({
                token: senderShield.token,
                amount: remainingAmount,
                timestamp: block.timestamp,
                exists: true,
                spent: false
            });

            emit Shielded(senderNewCommitment, senderShield.token, remainingAmount, 0);
        }

        emit Unshielded(senderCommitment, senderShield.token, amount, 0);
        emit Shielded(recipientCommitment, senderShield.token, netAmount, 0);
        emit SecretDelivered(encryptedSecret);

        // Track collected fees
        collectedFees[senderShield.token] += transferFee;
    }

    // Consolidate multiple Shields into one
    function consolidate(bytes32[] calldata secrets, bytes32 newCommitment) external nonReentrant whenNotPaused {
        if (secrets.length == 0) revert NoSecretsProvided();
        if (secrets.length > MAX_CONSOLIDATE_SHIELDS) revert TooManyShieldsToConsolidate();
        if (shields[newCommitment].exists) revert CommitmentAlreadyExists();
        if (newCommitment == bytes32(0)) revert EmptyCommitment();
        uint256 totalAmount = 0;
        address tokenAddress = address(0);
        bytes32[] memory oldCommitments = new bytes32[](secrets.length);

        for (uint i = 0; i < secrets.length; i++) {
            bytes32 commitment = this.generateCommitment(secrets[i], msg.sender);
            oldCommitments[i] = commitment;

            Shield storage Shield = shields[commitment];
            if (!Shield.exists) revert ShieldDoesNotExist();
            if (Shield.spent) revert ShieldAlreadySpent();

            if (tokenAddress == address(0)) {
                tokenAddress = Shield.token;
            } else {
                if (Shield.token != tokenAddress) revert AllShieldsMustUseSameToken();
            }

            // Check for overflow using library
            if (wouldOverflow(totalAmount, Shield.amount)) revert AmountOverflow();
            totalAmount += Shield.amount;
            Shield.spent = true;
        }

        if (totalAmount == 0) revert TotalAmountMustBePositive();
        if (tokenAddress == address(0)) revert InvalidToken();

        // Create new consolidated Shield
        shields[newCommitment] = Shield({
            token: tokenAddress,
            amount: totalAmount,
            timestamp: block.timestamp,
            exists: true,
            spent: false
        });

        emit ShieldConsolidated(oldCommitments, newCommitment);
        emit Shielded(newCommitment, tokenAddress, totalAmount, 0);
    }

    // Admin functions
    function setFees(
        uint256 _shieldFeePercent,
        uint256 _unshieldFeePercent,
        uint256 _transferFeePercent
    ) external onlyRole(FEE_MANAGER_ROLE) {
        if (_shieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_unshieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_transferFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();

        emit FeesUpdated(_shieldFeePercent, _unshieldFeePercent);

        shieldFeePercent = _shieldFeePercent;
        unshieldFeePercent = _unshieldFeePercent;
        transferFeePercent = _transferFeePercent;
    }

    function withdrawFees(address token, address recipient) external onlyRole(ADMIN_ROLE) {
        uint256 amount = collectedFees[token];
        if (amount == 0) revert NoFeesToWithdraw();

        collectedFees[token] = 0;
        IERC20Upgradeable(token).transfer(recipient, amount);
    }

    // Pause/unpause functions
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // Emergency withdrawal (only when paused) - only collected fees
    function emergencyWithdraw(address token, address recipient) external onlyRole(ADMIN_ROLE) whenPaused {
        uint256 amount = collectedFees[token];
        if (amount == 0) revert NoFeesToWithdraw();
        collectedFees[token] = 0;
        IERC20Upgradeable(token).transfer(recipient, amount);
    }

    // View functions
    function getShieldInfo(
        bytes32 commitment
    ) external view returns (bool exists, address token, uint256 amount, uint256 timestamp, bool spent) {
        Shield memory currentShield = shields[commitment];
        return (
            currentShield.exists,
            currentShield.token,
            currentShield.amount,
            currentShield.timestamp,
            currentShield.spent
        );
    }

    function getShieldBalance(bytes32 secret, address token) external view returns (uint256) {
        bytes32 commitment = this.generateCommitment(secret, msg.sender);
        Shield memory currentShield = shields[commitment];

        if (!currentShield.exists || currentShield.spent || currentShield.token != token) {
            return 0;
        }
        return currentShield.amount;
    }

    function isCommitmentActive(bytes32 commitment) external view returns (bool) {
        Shield memory currentShield = shields[commitment];
        return currentShield.exists && !currentShield.spent;
    }

    // Upgrade authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /**
     * @dev Validate Shield parameters
     * @param amount The Shield amount
     * @param token The token address
     * @param commitment The commitment hash
     */

    function validateShieldParams(uint256 amount, address token, bytes32 commitment) internal pure {
        if (!(amount > 0)) revert ZeroAmount();
        if (token == address(0)) revert EmptyToken();
        if (commitment == bytes32(0)) revert InvalidCommitment();
    }

    /**
     * @dev Check if amount would cause overflow
     * @param a First amount
     * @param b Second amount
     * @return True if addition would overflow
     */
    function wouldOverflow(uint256 a, uint256 b) internal pure returns (bool) {
        return a > type(uint256).max - b;
    }

    /**
     * @dev Calculate fee amount
     * @param amount The amount to calculate fee for
     * @param feePercent Fee percentage in basis points
     * @return The fee amount
     */
    function calculateFee(uint256 amount, uint256 feePercent) internal pure returns (uint256) {
        return (amount * feePercent) / FEE_DENOMINATOR;
    }

    /**
     * @dev Generate commitment hash
     * @param secret The secret value
     * @param recipient The recipient address
     * @return The commitment hash
     */
    function generateCommitment(bytes32 secret, address recipient) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(secret, recipient));
    }

    /**
     * @dev Generate deterministic commitment for sender
     * @param sender The sender address
     * @param nonce The nonce value
     * @return The commitment hash
     */
    function generateSenderCommitment(address sender, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(sender, nonce));
    }
}
