// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ILaserGun} from "./interfaces/ILaserGun.sol";
import {LaserGunLib} from "./libraries/LaserGunLib.sol";

contract LaserGun is 
    Initializable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ILaserGun
{
    using LaserGunLib for uint256;

    
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    
    // State variables
    mapping(bytes32 => Voucher) public vouchers;
    
    // User nonces for deterministic commitment generation
    mapping(address => uint256) public userNonces;

    // Public keys for encrypted secret delivery
    mapping(address => bytes) public publicKeys;
    
    // Fee settings
    uint256 public shieldFeePercent;     // Fee percentage in basis points (25 = 0.25%)
    uint256 public unshieldFeePercent;   // Fee percentage in basis points
    mapping(address => uint256) public collectedFees; // Token => accumulated fees
    
    // Constants
    uint256 public constant MAX_FEE_PERCENT = 1000; // 10% maximum fee
    uint256 public constant FEE_DENOMINATOR = 10000; // 100% = 10000 basis points
    uint256 public constant MAX_CONSOLIDATE_VOUCHERS = 10; // Maximum vouchers in consolidate
    uint256 public constant MIN_AMOUNT = 1; // Minimum amount (1 wei) to prevent dust attacks
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address admin,
        uint256 _shieldFeePercent,
        uint256 _unshieldFeePercent
    ) public initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        
        if (_shieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_unshieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(FEE_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        
        shieldFeePercent = _shieldFeePercent;
        unshieldFeePercent = _unshieldFeePercent;
    }
    
    // Public key registration
    function registerPublicKey(bytes calldata publicKey) external {
        publicKeys[msg.sender] = publicKey;
    }
    
    // Create voucher by depositing tokens (Shield operation)
    function deposit(
        uint256 amount,
        address token,
        bytes32 commitment
    ) external nonReentrant whenNotPaused {
        LaserGunLib.validateVoucherParams(amount, token, commitment);
        if (vouchers[commitment].exists) revert CommitmentAlreadyExists();
        
        // Calculate fee using library
        uint256 fee = amount.calculateFee(shieldFeePercent);
        uint256 netAmount = amount - fee;
        if (netAmount == 0) revert NetAmountMustBePositive();
        
        // Transfer tokens from sender (including fee)
        IERC20Upgradeable(token).transferFrom(msg.sender, address(this), amount);
        
        // Track collected fees
        collectedFees[token] += fee;
        
        // Create voucher with net amount
        vouchers[commitment] = Voucher({
            token: token,
            amount: netAmount,
            timestamp: block.timestamp,
            exists: true,
            spent: false
        });
        
        emit VoucherCreated(commitment, token, netAmount, fee);
        if (fee > 0) {
            emit FeeCollected(token, fee);
        }
    }
 

    // Redeem voucher with recipient-bound commitment to third party(Unshield operation)
    function redeem(
        bytes32 secret,
        uint256 redeemAmount,
        address recipient,
        bytes32 newCommitment  // For remaining balance (0x0 if no remaining balance)
    ) external nonReentrant whenNotPaused {
        if (redeemAmount < MIN_AMOUNT) revert AmountTooSmall();
        if (recipient == address(0)) revert InvalidRecipient();
       
        bytes32 commitment = LaserGunLib.generateCommitment(secret, msg.sender);
        Voucher storage voucher = vouchers[commitment];
        if (!voucher.exists) revert VoucherDoesNotExist();
        if (voucher.spent) revert VoucherAlreadySpent();
        if (redeemAmount > voucher.amount) revert InsufficientVoucherBalance();
        
        // Calculate fee using library
        uint256 fee = redeemAmount.calculateFee(unshieldFeePercent);
        uint256 netRedeemAmount = redeemAmount - fee;
        uint256 remainingAmount = voucher.amount - redeemAmount;
        
        // Mark current voucher as spent
        voucher.spent = true;
        
        // Track collected fees
        collectedFees[voucher.token] += fee;
        
        // Send net redeemed amount to recipient
        if (netRedeemAmount > 0) {
            IERC20Upgradeable(voucher.token).transfer(recipient, netRedeemAmount);
        }
        
        // Create new voucher for remaining balance if needed
        if (remainingAmount > 0) {
            if (newCommitment == bytes32(0)) revert NewCommitmentRequiredForRemainingBalance();
            if (vouchers[newCommitment].exists) revert CommitmentAlreadyExists();
            
            vouchers[newCommitment] = Voucher({
                token: voucher.token,
                amount: remainingAmount,
                timestamp: block.timestamp,
                exists: true,
                spent: false
            });
            
            emit VoucherCreated(newCommitment, voucher.token, remainingAmount, 0);
        }
        
        emit VoucherRedeemed(commitment, voucher.token, netRedeemAmount, fee);
        if (fee > 0) {
            emit FeeCollected(voucher.token, fee);
        }
    }
    
    // Create voucher for specific recipient (for transfers)
    function transfer(
        bytes32 secret,
        uint256 amount, 
        bytes32 recipientCommitment,
        bytes calldata encryptedSecret
    ) external nonReentrant whenNotPaused { 
        if (amount < MIN_AMOUNT) revert AmountTooSmall();
        if (encryptedSecret.length == 0) revert EncryptedSecretCannotBeEmpty();
        
        bytes32 senderCommitment = LaserGunLib.generateCommitment(secret, msg.sender);
        
        Voucher storage senderVoucher = vouchers[senderCommitment];
        if (!senderVoucher.exists) revert VoucherDoesNotExist();
        if (senderVoucher.spent) revert VoucherAlreadySpent();
        if (amount > senderVoucher.amount) revert InsufficientVoucherBalance();
        if (vouchers[recipientCommitment].exists) revert RecipientCommitmentAlreadyExists();
        
        uint256 remainingAmount = senderVoucher.amount - amount;
        
        // Mark sender's voucher as spent first (reentrancy protection)
        senderVoucher.spent = true;
        
        // Create voucher for recipient
        vouchers[recipientCommitment] = Voucher({
            token: senderVoucher.token,
            amount: amount,
            timestamp: block.timestamp,
            exists: true,
            spent: false
        });
        
        // Create new voucher for sender's remaining balance if any
        if (remainingAmount > 0) {
            uint256 nonce = userNonces[msg.sender]++;
            bytes32 senderNewCommitment = LaserGunLib.generateSenderCommitment(msg.sender, nonce);
            
            vouchers[senderNewCommitment] = Voucher({
                token: senderVoucher.token,
                amount: remainingAmount,
                timestamp: block.timestamp,
                exists: true,
                spent: false
            });
            
            emit VoucherCreated(senderNewCommitment, senderVoucher.token, remainingAmount, 0);
        }
        
        emit VoucherRedeemed(senderCommitment, senderVoucher.token,  amount, 0);
        emit VoucherCreated(recipientCommitment, senderVoucher.token, amount, 0);
        emit SecretDelivered(encryptedSecret);
    }
    
    // Consolidate multiple vouchers into one
    function consolidate(
        bytes32[] calldata secrets,
        bytes32 newCommitment
    ) external nonReentrant whenNotPaused {
        if (secrets.length == 0) revert NoSecretsProvided();
        if (secrets.length > MAX_CONSOLIDATE_VOUCHERS) revert TooManyVouchersToConsolidate();
        if (vouchers[newCommitment].exists) revert CommitmentAlreadyExists();
        if(newCommitment == bytes32(0)) revert EmptyCommitment();
        uint256 totalAmount = 0;
        address tokenAddress = address(0);
        bytes32[] memory oldCommitments = new bytes32[](secrets.length);
        
        for (uint i = 0; i < secrets.length; i++) {
            bytes32 commitment = LaserGunLib.generateCommitment(secrets[i], msg.sender);
            oldCommitments[i] = commitment;
            
            Voucher storage voucher = vouchers[commitment];
            if (!voucher.exists) revert VoucherDoesNotExist();
            if (voucher.spent) revert VoucherAlreadySpent();
            
            if (tokenAddress == address(0)) {
                tokenAddress = voucher.token;
            } else {
                if (voucher.token != tokenAddress) revert AllVouchersMustUseSameToken();
            }
            
            // Check for overflow using library
            if (LaserGunLib.wouldOverflow(totalAmount, voucher.amount)) revert AmountOverflow();
            totalAmount += voucher.amount;
            voucher.spent = true;
        }
        
        if (totalAmount == 0) revert TotalAmountMustBePositive();
        if (tokenAddress == address(0)) revert InvalidToken();
        
        // Create new consolidated voucher
        vouchers[newCommitment] = Voucher({
            token: tokenAddress,
            amount: totalAmount,
            timestamp: block.timestamp,
            exists: true,
            spent: false
        });
        
        emit VoucherConsolidated(oldCommitments, newCommitment);
        emit VoucherCreated(newCommitment, tokenAddress, totalAmount, 0);
    }
    
    // Admin functions
    function setFees(uint256 _shieldFeePercent, uint256 _unshieldFeePercent) external onlyRole(FEE_MANAGER_ROLE) {
        if (_shieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        if (_unshieldFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        
        emit FeesUpdated(_shieldFeePercent , _unshieldFeePercent);
        
        shieldFeePercent = _shieldFeePercent;
        unshieldFeePercent = _unshieldFeePercent;
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
    function getVoucherInfo(bytes32 commitment) external view returns (
        bool exists,
        address token,
        uint256 amount,
        uint256 timestamp,
        bool spent
    ) {
        Voucher memory voucher = vouchers[commitment];
        return (voucher.exists, voucher.token, voucher.amount, voucher.timestamp, voucher.spent);
    }
    
    function generateCommitment(bytes32 secret, address recipient) external pure returns (bytes32) {
        return LaserGunLib.generateCommitment(secret, recipient);
    }
    
    function getMyVoucherBalance(bytes32 secret, address token) external view returns (uint256) {
        bytes32 commitment = LaserGunLib.generateCommitment(secret, msg.sender);
        Voucher memory voucher = vouchers[commitment];
        
        if (!voucher.exists || voucher.spent || voucher.token != token) {
            return 0;
        }
        return voucher.amount;
    }
    
    function isCommitmentActive(bytes32 commitment) external view returns (bool) {
        Voucher memory voucher = vouchers[commitment];
        return voucher.exists && !voucher.spent;
    }
    
    // Upgrade authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}