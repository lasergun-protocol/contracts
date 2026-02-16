// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITypes} from "../interfaces/ITypes.sol";
import {ILaserGun} from "../interfaces/ILaserGun.sol";
import {ShieldFlags} from "./ShieldFlags.sol";

/**
 * @title ShieldOperations
 * @author Ilya  A. Shlyakhovoy
 * @notice Library for core shield operations (shield, unshield, transfer, consolidate)
 * @dev Contains the main business logic for shield operations
 */
library ShieldOperations {
    /**
     * @notice Create a new shield with tokens
     * @param shields Mapping of commitment hashes to shield data
     * @param userNonces User nonces for deterministic commitment generation
     * @param userShieldCount Mapping to track number of shields per user
     * @param sender Address of the user creating the shield
     * @param amount Amount of tokens to shield
     * @param token Address of the ERC20 token
     * @param commitment Unique commitment hash
     * @param feePercent Fee percentage in basis points
     * @param feeDenominator Fee denominator for calculation
     * @param maxShieldsPerUser Maximum shields allowed per user
     * @param minAmount Minimum amount for shield
     * @param maxOperationAmount Maximum amount for single operation
     * @return fee Amount of fee charged
     */
    function createShield(
        mapping(bytes32 => ITypes.Shield) storage shields,
        mapping(address => uint64) storage userNonces,
        mapping(address => uint256) storage userShieldCount,
        address sender,
        uint256 amount,
        address token,
        bytes32 commitment,
        bytes32 /* bloomFilter - unused parameter */,
        uint16 feePercent,
        uint16 feeDenominator,
        uint256 maxShieldsPerUser,
        uint64 minAmount,
        uint256 maxOperationAmount,
        address contractAddress
    ) internal returns (uint256 fee) {
        _validateCreateShieldParams(amount, token, commitment, minAmount, maxOperationAmount);
        _validateShieldLimits(shields, userShieldCount, sender, commitment, maxShieldsPerUser);
        
        fee = _calculateFee(amount, feePercent, feeDenominator);
        uint256 netAmount = amount - fee;
        
        if (netAmount == 0) revert ILaserGun.NetAmountMustBePositive();
        
        _createShield(shields, commitment, token, netAmount);
        _updateUserState(userNonces, userShieldCount, sender);
        _transferTokens(token, sender, amount, contractAddress);
    }
    
    /**
     * @notice Validates parameters for creating a new shield
     * @param amount Amount of tokens to shield
     * @param token Address of the ERC20 token
     * @param commitment Unique commitment hash
     * @param minAmount Minimum amount for shield
     * @param maxOperationAmount Maximum amount for single operation
     * @dev Reverts with appropriate error if any parameter is invalid
     */
    function _validateCreateShieldParams(
        uint256 amount,
        address token,
        bytes32 commitment,
        uint64 minAmount,
        uint256 maxOperationAmount
    ) private pure {
        if (amount == 0) revert ILaserGun.ZeroAmount();
        if (amount < minAmount) revert ILaserGun.AmountTooSmall();
        if (amount > maxOperationAmount) revert ILaserGun.AmountTooLarge();
        if (token == address(0)) revert ILaserGun.EmptyToken();
        if (commitment == bytes32(0)) revert ILaserGun.EmptyCommitment();
    }
    
    /**
     * @notice Validates shield limits for user and commitment
     * @param shields Mapping of commitment hashes to shield data
     * @param userShieldCount Mapping to track number of shields per user
     * @param sender Address of the user creating the shield
     * @param commitment Unique commitment hash
     * @param maxShieldsPerUser Maximum shields allowed per user
     * @dev Checks if commitment already exists and if user has reached shield limit
     */
    function _validateShieldLimits(
        mapping(bytes32 => ITypes.Shield) storage shields,
        mapping(address => uint256) storage userShieldCount,
        address sender,
        bytes32 commitment,
        uint256 maxShieldsPerUser
    ) private view {
        if (shields[commitment].flags & ShieldFlags.setExists(0, true) != 0) revert ILaserGun.CommitmentAlreadyExists();
        if (maxShieldsPerUser < userShieldCount[sender] ) revert ILaserGun.TooManyShields();
    }
    
    /**
     * @notice Calculates fee amount based on percentage
     * @param amount Amount to calculate fee for
     * @param feePercent Fee percentage in basis points
     * @param feeDenominator Fee denominator for calculation
     * @return fee Calculated fee amount
     * @dev Uses simple percentage calculation: (amount * feePercent) / feeDenominator
     */
    function _calculateFee(uint256 amount, uint16 feePercent, uint16 feeDenominator) private pure returns (uint256) {
        return (amount * feePercent) / feeDenominator;
    }
    
    /**
     * @notice Calculates fee and validates that net amount is positive
     * @param amount Amount to calculate fee for
     * @param feePercent Fee percentage in basis points
     * @param feeDenominator Fee denominator for calculation
     * @return fee Calculated fee amount
     * @return netAmount Amount after deducting fee
     * @dev Reverts if net amount would be zero after fee deduction
     */
    function _calculateAndValidateFee(uint256 amount, uint16 feePercent, uint16 feeDenominator)
        private pure returns (uint256 fee, uint256 netAmount) {
        fee = _calculateFee(amount, feePercent, feeDenominator);
        netAmount = amount - fee;
        if (netAmount == 0) revert ILaserGun.NetAmountMustBePositive();
    }
    
    /**
     * @notice Creates a new shield with the given parameters
     * @param shields Mapping of commitment hashes to shield data
     * @param commitment Unique commitment hash for the shield
     * @param token Address of the ERC20 token
     * @param netAmount Amount of tokens after fee deduction
     * @dev Creates a new shield entry with exists flag set and spent flag cleared
     */
    function _createShield(
        mapping(bytes32 => ITypes.Shield) storage shields,
        bytes32 commitment,
        address token,
        uint256 netAmount
    ) private {
        shields[commitment] = ITypes.Shield({
            token: token,
            amount: netAmount,
            timestamp: uint64(block.timestamp),
            flags: ShieldFlags.setExists(ShieldFlags.setSpent(0, false), true)
        });
    }
    
    /**
     * @notice Updates user state after creating a shield
     * @param userNonces User nonces for deterministic commitment generation
     * @param userShieldCount Mapping to track number of shields per user
     * @param sender Address of the user creating the shield
     * @dev Increments both nonce and shield count for the user
     */
    function _updateUserState(
        mapping(address => uint64) storage userNonces,
        mapping(address => uint256) storage userShieldCount,
        address sender
    ) private {
        ++userNonces[sender];
        ++userShieldCount[sender];
    }
    
    /**
     * @notice Transfers tokens from user to contract
     * @param token Address of the ERC20 token
     * @param sender Address of the user transferring tokens
     * @param amount Amount of tokens to transfer
     * @param contractAddress Address of the contract receiving tokens
     * @dev Validates user balance before transfer and reverts on failure
     */
    function _transferTokens(address token, address sender, uint256 amount, address contractAddress) private {
        uint256 userBalance = IERC20(token).balanceOf(sender);
        if (userBalance < amount) revert ILaserGun.InsufficientTokenBalance();
        
        bool success = IERC20(token).transferFrom(sender, contractAddress, amount);
        if (!success) revert ILaserGun.TransferFailed();
    }

    /**
     * @notice Withdraw tokens from a shield
     * @param shields Mapping of commitment hashes to shield data
     * @param userNonces User nonces for deterministic commitment generation
     * @param sender Address of the user withdrawing
     * @param commitment Commitment hash of the shield
     * @param redeemAmount Amount of tokens to withdraw
     * @param recipient Address of the recipient
     * @param newCommitment New commitment for remaining balance
     * @param feePercent Fee percentage in basis points
     * @param feeDenominator Fee denominator for calculation
     * @param minAmount Minimum amount for shield
     * @param maxOperationAmount Maximum amount for single operation
     * @return fee Amount of fee charged
     * @return netRedeemAmount Net amount after fee
     */
    function unshield(
        mapping(bytes32 => ITypes.Shield) storage shields,
        mapping(address => uint64) storage userNonces,
        address sender,
        bytes32 commitment,
        uint256 redeemAmount,
        address recipient,
        bytes32 newCommitment,
        uint16 feePercent,
        uint16 feeDenominator,
        uint64 minAmount,
        uint256 maxOperationAmount,
        address contractAddress
    ) internal returns (uint256 fee, uint256 netRedeemAmount) {
        _validateUnshieldParams(redeemAmount, recipient, minAmount, maxOperationAmount);
        
        // Use userNonces to avoid lint warning
        uint64 nonceValue = userNonces[sender];
        nonceValue; // Suppress unused variable warning
        
        ITypes.Shield storage shield = shields[commitment];
        
        // Check if shield exists and is not spent
        if (!ShieldFlags.getExists(shield.flags)) revert ILaserGun.ShieldDoesNotExist();
        if (ShieldFlags.getSpent(shield.flags)) revert ILaserGun.ShieldAlreadySpent();
        
        (fee, netRedeemAmount) = _calculateAndValidateFee(redeemAmount, feePercent, feeDenominator);
        
        _handleRemainingBalance(shields, shield, newCommitment, redeemAmount);
        _executeUnshield(shields, shield, recipient, netRedeemAmount, contractAddress);
    }
    
    /**
     * @notice Validates parameters for unshielding tokens
     * @param redeemAmount Amount of tokens to withdraw
     * @param recipient Address of the recipient
     * @param minAmount Minimum amount for shield
     * @param maxOperationAmount Maximum amount for single operation
     * @dev Reverts with appropriate error if any parameter is invalid
     */
    function _validateUnshieldParams(
        uint256 redeemAmount,
        address recipient,
        uint64 minAmount,
        uint256 maxOperationAmount
    ) private pure {
        if (redeemAmount == 0) revert ILaserGun.ZeroAmount();
        if (redeemAmount < minAmount) revert ILaserGun.AmountTooSmall();
        if (redeemAmount > maxOperationAmount) revert ILaserGun.AmountTooLarge();
        if (recipient == address(0)) revert ILaserGun.InvalidRecipient();
    }
    
    /**
     * @notice Generates a deterministic commitment hash
     * @param secret Secret value for commitment
     * @param sender Address of the user
     * @param nonce User nonce for uniqueness
     * @param contractAddress Address of the contract
     * @return commitment Generated commitment hash
     * @dev Uses keccak256 with multiple entropy sources for security
     */
    function _generateCommitment(
        bytes32 secret,
        address sender,
        uint64 nonce,
        address contractAddress
    ) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(secret, sender, nonce, block.timestamp, block.prevrandao, contractAddress)
        );
    }
    
    /**
     * @notice Validates shield and returns it for unshielding
     * @param shields Mapping of commitment hashes to shield data
     * @param commitment Commitment hash of the shield
     * @param redeemAmount Amount of tokens to withdraw
     * @return shield Validated shield storage reference
     * @dev Checks shield existence, spent status, escrow status, and balance
     */
    function _validateAndGetShieldForUnshield(
        mapping(bytes32 => ITypes.Shield) storage shields,
        bytes32 commitment,
        uint256 redeemAmount
    ) private view returns (ITypes.Shield storage shield) {
        shield = shields[commitment];
        if (!ShieldFlags.getExists(shield.flags)) revert ILaserGun.ShieldDoesNotExist();
        if (ShieldFlags.getSpent(shield.flags)) revert ILaserGun.ShieldAlreadySpent();
        if (ShieldFlags.getIsEscrow(shield.flags)) revert ILaserGun.CannotUnshieldEscrowDirectly();
        if (shield.amount < redeemAmount) revert ILaserGun.InsufficientShieldBalance();
    }
    
    /**
     * @notice Handles remaining balance after unshielding
     * @param shields Mapping of commitment hashes to shield data
     * @param shield Original shield being unshielded
     * @param newCommitment New commitment for remaining balance
     * @param redeemAmount Amount being unshielded
     * @dev Creates new shield for remaining amount if any, requires new commitment
     */
    function _handleRemainingBalance(
        mapping(bytes32 => ITypes.Shield) storage shields,
        ITypes.Shield storage shield,
        bytes32 newCommitment,
        uint256 redeemAmount
    ) private {
        if (shield.amount < redeemAmount) revert ILaserGun.InsufficientShieldBalance();
        uint256 remainingAmount = shield.amount - redeemAmount;
        if (remainingAmount > 0) {
            if (newCommitment == bytes32(0)) {
                revert ILaserGun.NewCommitmentRequiredForRemainingBalance();
            }
            if (shields[newCommitment].flags & ShieldFlags.setExists(0, true) != 0) {
                revert ILaserGun.CommitmentAlreadyExists();
            }
            
            // Create new shield for remaining amount
            shields[newCommitment] = ITypes.Shield({
                token: shield.token,
                amount: remainingAmount,
                timestamp: uint64(block.timestamp),
                flags: ShieldFlags.setExists(ShieldFlags.setSpent(0, false), true)
            });
        }
    }
    
    /**
     * @notice Executes the unshielding operation
     * @param shield Shield being unshielded
     * @param recipient Address of the recipient
     * @param netRedeemAmount Net amount after fee
     * @param contractAddress Address of the contract
     * @dev Marks shield as spent and transfers tokens to recipient
     */
    function _executeUnshield(
        mapping(bytes32 => ITypes.Shield) storage /* shields */,
        ITypes.Shield storage shield,
        address recipient,
        uint256 netRedeemAmount,
        address contractAddress
    ) private {
        // Mark original shield as spent
        shield.flags = ShieldFlags.setSpent(shield.flags, true);

        // Transfer tokens to recipient
        uint256 contractBalance = IERC20(shield.token).balanceOf(contractAddress);
        if (contractBalance < netRedeemAmount) revert ILaserGun.InsufficientContractBalance();
        
        bool success = IERC20(shield.token).transfer(recipient, netRedeemAmount);
        if (!success) revert ILaserGun.TransferFailed();
    }

    /**
     * @notice Private transfer of tokens between users
     * @param shields Mapping of commitment hashes to shield data
     * @param userNonces User nonces for deterministic commitment generation
     * @param sender Address of the sender
     * @param senderCommitment Commitment hash of the sender's shield
     * @param amount Amount of tokens to transfer
     * @param recipientCommitment Commitment for the recipient's shield
     * @param feePercent Fee percentage in basis points
     * @param feeDenominator Fee denominator for calculation
     * @param minAmount Minimum amount for shield
     * @param maxOperationAmount Maximum amount for single operation
     * @return fee Amount of fee charged
     * @return netAmount Net amount after fee
     */
    function transfer(
        mapping(bytes32 => ITypes.Shield) storage shields,
        mapping(address => uint64) storage userNonces,
        address sender,
        bytes32 senderCommitment,
        uint256 amount,
        bytes32 recipientCommitment,
        uint16 feePercent,
        uint16 feeDenominator,
        uint64 minAmount,
        uint256 maxOperationAmount,
        address contractAddress
    ) internal returns (uint256 fee, uint256 netAmount) {
        _validateTransferParams(amount, recipientCommitment, minAmount, maxOperationAmount);
        _validateRecipientCommitment(shields, recipientCommitment);
        
        // Use userNonces to avoid lint warning
        uint64 nonceValue = userNonces[sender];
        nonceValue; // Suppress unused variable warning
        
        ITypes.Shield storage senderShield = shields[senderCommitment];
        
        (fee, netAmount) = _calculateAndValidateFee(amount, feePercent, feeDenominator);
        
        _handleTransferRemainingBalance(shields, userNonces, senderShield, sender, amount, contractAddress);
        _executeTransfer(shields, senderShield, recipientCommitment, netAmount);
    }
    
    /**
     * @notice Validates parameters for transfer operation
     * @param amount Amount of tokens to transfer
     * @param recipientCommitment Commitment for the recipient's shield
     * @param minAmount Minimum amount for shield
     * @param maxOperationAmount Maximum amount for single operation
     * @dev Reverts with appropriate error if any parameter is invalid
     */
    function _validateTransferParams(
        uint256 amount,
        bytes32 recipientCommitment,
        uint64 minAmount,
        uint256 maxOperationAmount
    ) private pure {
        if (amount == 0) revert ILaserGun.ZeroAmount();
        if (amount < minAmount) revert ILaserGun.AmountTooSmall();
        if (amount > maxOperationAmount) revert ILaserGun.AmountTooLarge();
        if (recipientCommitment == bytes32(0)) {
            revert ILaserGun.EmptyCommitment();
        }
    }
    
    /**
     * @notice Validates that recipient commitment doesn't already exist
     * @param shields Mapping of commitment hashes to shield data
     * @param recipientCommitment Commitment for the recipient's shield
     * @dev Reverts if recipient commitment already exists
     */
    function _validateRecipientCommitment(
        mapping(bytes32 => ITypes.Shield) storage shields,
        bytes32 recipientCommitment
    ) private view {
        if (shields[recipientCommitment].flags & ShieldFlags.setExists(0, true) != 0) {
            revert ILaserGun.RecipientCommitmentAlreadyExists();
        }
    }
    
    /**
     * @notice Validates sender shield and returns it for transfer
     * @param shields Mapping of commitment hashes to shield data
     * @param senderCommitment Commitment hash of the sender's shield
     * @param amount Amount of tokens to transfer
     * @return senderShield Validated sender shield storage reference
     * @dev Checks shield existence, spent status, escrow status, and balance
     */
    function _validateAndGetShieldForTransfer(
        mapping(bytes32 => ITypes.Shield) storage shields,
        bytes32 senderCommitment,
        uint256 amount
    ) private view returns (ITypes.Shield storage senderShield) {
        senderShield = shields[senderCommitment];
        if (!ShieldFlags.getExists(senderShield.flags)) revert ILaserGun.ShieldDoesNotExist();
        if (ShieldFlags.getSpent(senderShield.flags)) revert ILaserGun.ShieldAlreadySpent();
        if (ShieldFlags.getIsEscrow(senderShield.flags)) revert ILaserGun.CannotTransferEscrowDirectly();
        if (senderShield.amount < amount) revert ILaserGun.InsufficientShieldBalance();
    }
    
    /**
     * @notice Handles remaining balance after transfer
     * @param shields Mapping of commitment hashes to shield data
     * @param userNonces User nonces for deterministic commitment generation
     * @param senderShield Original shield being transferred from
     * @param sender Address of the sender
     * @param amount Amount being transferred
     * @param contractAddress Address of the contract
     * @dev Creates new shield for remaining amount if any using deterministic commitment
     */
    function _handleTransferRemainingBalance(
        mapping(bytes32 => ITypes.Shield) storage shields,
        mapping(address => uint64) storage userNonces,
        ITypes.Shield storage senderShield,
        address sender,
        uint256 amount,
        address contractAddress
    ) private {
        uint256 remainingAmount = senderShield.amount - amount;
        if (remainingAmount > 0) {
            // Create new shield for remaining amount with same token
            bytes32 newCommitment = keccak256(abi.encodePacked(
                keccak256(abi.encodePacked("remaining", senderShield.token)),
                sender,
                userNonces[sender]++,
                block.timestamp,
                block.prevrandao,
                contractAddress
            ));
            
            shields[newCommitment] = ITypes.Shield({
                token: senderShield.token,
                amount: remainingAmount,
                timestamp: uint64(block.timestamp),
                flags: ShieldFlags.setExists(ShieldFlags.setSpent(0, false), true)
            });
        }
    }
    
    /**
     * @notice Executes the transfer operation
     * @param shields Mapping of commitment hashes to shield data
     * @param senderShield Shield being transferred from
     * @param recipientCommitment Commitment for the recipient's shield
     * @param netAmount Net amount after fee
     * @dev Marks sender shield as spent and creates recipient shield
     */
    function _executeTransfer(
        mapping(bytes32 => ITypes.Shield) storage shields,
        ITypes.Shield storage senderShield,
        bytes32 recipientCommitment,
        uint256 netAmount
    ) private {
        // Mark original shield as spent
        senderShield.flags = ShieldFlags.setSpent(senderShield.flags, true);

        // Create recipient's shield
        shields[recipientCommitment] = ITypes.Shield({
            token: senderShield.token,
            amount: netAmount,
            timestamp: uint64(block.timestamp),
            flags: ShieldFlags.setExists(ShieldFlags.setSpent(0, false), true)
        });
    }

    /**
     * @notice Consolidate multiple shields into one
     * @param shields Mapping of commitment hashes to shield data
     * @param userNonces User nonces for deterministic commitment generation
     * @param sender Address of the user consolidating shields
     * @param commitments Array of shield commitments
     * @param newCommitment New commitment for the consolidated shield
     * @param maxConsolidateShields Maximum number of shields that can be consolidated
     * @param minAmount Minimum amount for shield
     * @return totalAmount Total amount of tokens in consolidated shield
     * @return token Address of the token
     */
    function consolidate(
        mapping(bytes32 => ITypes.Shield) storage shields,
        mapping(address => uint64) storage userNonces,
        address sender,
        bytes32[] calldata commitments,
        bytes32 newCommitment,
        uint8 maxConsolidateShields,
        uint64 minAmount
    ) internal returns (uint256 totalAmount, address token) {
        _validateConsolidateParams(commitments, newCommitment, maxConsolidateShields, shields);
        
        (totalAmount, token) = _processShieldsForConsolidation(shields, userNonces, sender, commitments);
        
        _validateConsolidateAmount(totalAmount, minAmount);
        
        _createConsolidatedShield(shields, newCommitment, token, totalAmount);
    }
    
    /**
     * @notice Validates parameters for consolidation operation
     * @param commitments Array of shield commitments to consolidate
     * @param newCommitment New commitment for the consolidated shield
     * @param maxConsolidateShields Maximum number of shields that can be consolidated
     * @param shields Mapping of commitment hashes to shield data
     * @dev Reverts with appropriate error if any parameter is invalid
     */
    function _validateConsolidateParams(
        bytes32[] calldata commitments,
        bytes32 newCommitment,
        uint8 maxConsolidateShields,
        mapping(bytes32 => ITypes.Shield) storage shields
    ) private view {
        if (commitments.length == 0) revert ILaserGun.NoSecretsProvided();
        if (commitments.length > maxConsolidateShields) revert ILaserGun.TooManyShieldsToConsolidate();
        if (newCommitment == bytes32(0)) {
            revert ILaserGun.EmptyCommitment();
        }
        if (shields[newCommitment].flags & ShieldFlags.setExists(0, true) != 0) {
            revert ILaserGun.CommitmentAlreadyExists();
        }
    }
    
    /**
     * @notice Processes shields for consolidation, validating and marking them as spent
     * @param shields Mapping of commitment hashes to shield data
     * @param userNonces User nonces for deterministic commitment generation
     * @param sender Address of the user consolidating shields
     * @param commitments Array of shield commitments to consolidate
     * @return totalAmount Total amount of tokens in all shields
     * @return token Address of the token (must be same for all shields)
     * @dev Validates each shield, ensures token consistency, and marks shields as spent
     */
    function _processShieldsForConsolidation(
        mapping(bytes32 => ITypes.Shield) storage shields,
        mapping(address => uint64) storage userNonces,
        address sender,
        bytes32[] calldata commitments
    ) private returns (uint256 totalAmount, address token) {
        ITypes.Shield memory firstShield;
        totalAmount = 0;
        
        // Use userNonces to avoid lint warning
        uint64 nonceValue = userNonces[sender];
        nonceValue; // Suppress unused variable warning
        
        for (uint256 i = 0; i < commitments.length; i++) {
            bytes32 commitment = commitments[i];
            
            ITypes.Shield storage currentShield = shields[commitment];
            _validateShieldForConsolidation(currentShield);
            
            if (i == 0) {
                firstShield = currentShield;
                token = currentShield.token;
            } else {
                _validateTokenConsistency(currentShield, token);
            }
            
            totalAmount = _addToTotal(totalAmount, currentShield.amount);
            
            // Mark shield as spent
            currentShield.flags = ShieldFlags.setSpent(currentShield.flags, true);
        }
    }
    
    /**
     * @notice Validates shield for consolidation
     * @param currentShield Shield to validate
     * @dev Checks shield existence, spent status, and escrow status
     */
    function _validateShieldForConsolidation(ITypes.Shield storage currentShield) private view {
        if (!ShieldFlags.getExists(currentShield.flags)) revert ILaserGun.ShieldDoesNotExist();
        if (ShieldFlags.getSpent(currentShield.flags)) revert ILaserGun.ShieldAlreadySpent();
        if (ShieldFlags.getIsEscrow(currentShield.flags)) revert ILaserGun.CannotTransferEscrowDirectly();
    }
    
    /**
     * @notice Validates that all shields use the same token
     * @param currentShield Shield to validate
     * @param token Expected token address
     * @dev Reverts if shield token doesn't match expected token
     */
    function _validateTokenConsistency(ITypes.Shield storage currentShield, address token) private view {
        if (currentShield.token != token) {
            revert ILaserGun.AllShieldsMustUseSameToken();
        }
    }
    
    /**
     * @notice Adds amount to total with overflow protection
     * @param totalAmount Current total amount
     * @param amount Amount to add
     * @return New total amount after addition
     * @dev Reverts if addition would cause overflow
     */
    function _addToTotal(uint256 totalAmount, uint256 amount) private pure returns (uint256) {
        if (totalAmount > type(uint256).max - amount) {
            revert ILaserGun.AmountOverflow();
        }
        return totalAmount + amount;
    }
    
    /**
     * @notice Validates total amount for consolidation
     * @param totalAmount Total amount of tokens in consolidated shield
     * @param minAmount Minimum amount for shield
     * @dev Reverts if total amount is below minimum or zero
     */
    function _validateConsolidateAmount(uint256 totalAmount, uint64 minAmount) private pure {
        if (totalAmount < minAmount) revert ILaserGun.AmountTooSmall();
        if (totalAmount == 0) revert ILaserGun.TotalAmountMustBePositive();
    }
    
    /**
     * @notice Creates a new consolidated shield
     * @param shields Mapping of commitment hashes to shield data
     * @param newCommitment New commitment for the consolidated shield
     * @param token Address of the token
     * @param totalAmount Total amount of tokens in consolidated shield
     * @dev Creates a new shield entry with exists flag set and spent flag cleared
     */
    function _createConsolidatedShield(
        mapping(bytes32 => ITypes.Shield) storage shields,
        bytes32 newCommitment,
        address token,
        uint256 totalAmount
    ) private {
        shields[newCommitment] = ITypes.Shield({
            token: token,
            amount: totalAmount,
            timestamp: uint64(block.timestamp),
            flags: ShieldFlags.setExists(ShieldFlags.setSpent(0, false), true)
        });
    }
}