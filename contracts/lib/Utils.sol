// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITypes} from "../interfaces/ITypes.sol";
import {ILaserGun} from "../interfaces/ILaserGun.sol";
import {ShieldFlags} from "./ShieldFlags.sol";

/**
 * @title Utils
 * @notice Library for utility functions used throughout the LaserGun contract
 * @dev Contains helper functions for validation, calculations, and random number generation
 */
library Utils {
    /**
     * @notice Validate shield parameters
     * @param amount Amount of tokens
     * @param token Address of the token
     * @param commitment Commitment hash
     * @param minAmount Minimum amount allowed
     * @param maxOperationAmount Maximum amount for single operation
     */
    function validateShieldParams(
        uint256 amount,
        address token,
        bytes32 commitment,
        uint64 minAmount,
        uint256 maxOperationAmount
    ) internal pure {
        if (amount == 0) revert ILaserGun.ZeroAmount();
        if (amount < minAmount) revert ILaserGun.AmountTooSmall();
        if (amount > maxOperationAmount) revert ILaserGun.AmountTooLarge();
        if (token == address(0)) revert ILaserGun.EmptyToken();
        if (commitment == bytes32(0)) revert ILaserGun.EmptyCommitment();
    }

    /**
     * @notice Validate unshield parameters
     * @param redeemAmount Amount to redeem
     * @param recipient Address of the recipient
     * @param minAmount Minimum amount allowed
     * @param maxOperationAmount Maximum amount for single operation
     */
    function validateUnshieldParams(
        uint256 redeemAmount,
        address recipient,
        uint64 minAmount,
        uint256 maxOperationAmount
    ) internal pure {
        if (redeemAmount == 0) revert ILaserGun.ZeroAmount();
        if (redeemAmount < minAmount) revert ILaserGun.AmountTooSmall();
        if (redeemAmount > maxOperationAmount) revert ILaserGun.AmountTooLarge();
        if (recipient == address(0)) revert ILaserGun.InvalidRecipient();
    }

    /**
     * @notice Validate transfer parameters
     * @param amount Amount to transfer
     * @param recipientCommitment Recipient's commitment
     * @param minAmount Minimum amount allowed
     * @param maxOperationAmount Maximum amount for single operation
     */
    function validateTransferParams(
        uint256 amount,
        bytes32 recipientCommitment,
        uint64 minAmount,
        uint256 maxOperationAmount
    ) external pure {
        if (amount == 0) revert ILaserGun.ZeroAmount();
        if (amount < minAmount) revert ILaserGun.AmountTooSmall();
        if (amount > maxOperationAmount) revert ILaserGun.AmountTooLarge();
        if (recipientCommitment == bytes32(0)) revert ILaserGun.EmptyCommitment();
    }

    /**
     * @notice Validate consolidate parameters
     * @param secrets Array of secrets
     * @param newCommitment New commitment for consolidated shield
     * @param maxConsolidateShields Maximum number of shields to consolidate
     */
    function validateConsolidateParams(
        bytes32[] calldata secrets,
        bytes32 newCommitment,
        uint8 maxConsolidateShields
    ) external pure {
        if (secrets.length == 0) revert ILaserGun.NoSecretsProvided();
        if (secrets.length > maxConsolidateShields) revert ILaserGun.TooManyShieldsToConsolidate();
        if (newCommitment == bytes32(0)) revert ILaserGun.EmptyCommitment();
    }

    /**
     * @notice Validate operation limits and rate limiting
     * @param userOperationCount Mapping of user operation counts
     * @param userLastOperationTime Mapping of user last operation times
     * @param userLastOperationTimeByType Mapping of user last operation times by type
     * @param sender Address of the user
     * @param amount Amount of tokens
     * @param isCreatingShield Whether the operation creates a new shield
     * @param operationType Type of operation for rate limiting
     * @param maxOperationAmount Maximum amount for single operation
     * @param operationCooldown Operation cooldown period
     * @param maxShieldsPerUser Maximum shields per user
     * @param userShieldCount Current shield count for user
     */
    function validateOperationLimits(
        mapping(address => uint256) storage userOperationCount,
        mapping(address => uint256) storage userLastOperationTime,
        mapping(address => mapping(string => uint256)) storage userLastOperationTimeByType,
        address sender,
        uint256 amount,
        bool isCreatingShield,
        string memory operationType,
        uint256 maxOperationAmount,
        uint32 operationCooldown,
        uint256 maxShieldsPerUser,
        uint256 userShieldCount
    ) internal {
        // Check operation amount limit
        if (amount > maxOperationAmount) revert ILaserGun.AmountTooLarge();
        
        // Check operation cooldown
        if (block.timestamp < userLastOperationTime[sender] + operationCooldown) {
            revert ILaserGun.OperationTooFrequent();
        }
        
        // Check operation-specific cooldown
        if (block.timestamp < userLastOperationTimeByType[sender][operationType] + operationCooldown) {
            revert ILaserGun.OperationTooFrequent();
        }
        
        // Check shield count limit if creating a new shield
        if (isCreatingShield && userShieldCount >= maxShieldsPerUser) {
            revert ILaserGun.TooManyShields();
        }
        
        // Update operation tracking
        userOperationCount[sender]++;
        userLastOperationTime[sender] = block.timestamp;
        userLastOperationTimeByType[sender][operationType] = block.timestamp;
    }

    /**
     * @notice Check if addition would cause overflow
     * @param a First value
     * @param b Second value
     * @return true if addition would overflow
     */
    function wouldOverflow(uint256 a, uint256 b) internal pure returns (bool) {
        return a > type(uint256).max - b;
    }

    /**
     * @notice Calculate fee amount
     * @param amount Base amount
     * @param feePercent Fee percentage in basis points
     * @param feeDenominator Fee denominator for calculation
     * @return fee Fee amount
     */
    function calculateFee(
        uint256 amount,
        uint16 feePercent,
        uint16 feeDenominator
    ) external pure returns (uint256 fee) {
        return (amount * feePercent) / feeDenominator;
    }

    /**
     * @notice Generate a secure random number
     * @return random Random number
     */
    function secureRandom() internal view returns (uint256) {
        return uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    msg.sender,
                    gasleft()
                )
            )
        );
    }

    /**
     * @notice Generate random bytes of specified length
     * @param length Number of bytes to generate
     * @return randomBytes Random bytes
     */
    function secureRandomBytes(uint32 length) internal view returns (bytes memory randomBytes) {
        if (length == 0) revert ILaserGun.InvalidParameter();
        if (length > 32) revert ILaserGun.InvalidParameter();
        
        uint256 randomValue = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    msg.sender,
                    gasleft(),
                    length
                )
            )
        );
        
        randomBytes = new bytes(length);
        for (uint32 i = 0; i < length; i++) {
            randomBytes[i] = bytes1(uint8(randomValue >> (8 * i)));
        }
    }

    /**
     * @notice Generate commitment from secret and address with additional entropy
     * @param secret Secret value
     * @param recipient Address of the recipient
     * @param nonce User nonce for uniqueness
     * @param contractAddress Address of the contract
     * @return commitment Commitment hash
     */
    function generateCommitment(
        bytes32 secret,
        address recipient,
        uint64 nonce,
        address contractAddress
    ) internal view returns (bytes32 commitment) {
        return keccak256(
            abi.encodePacked(
                secret,
                recipient,
                nonce,
                block.timestamp,
                block.prevrandao,
                contractAddress
            )
        );
    }

    /**
     * @notice Generate sender-specific commitment
     * @param sender Address of the sender
     * @param nonce User nonce
     * @param contractAddress Address of the contract
     * @return commitment Commitment hash
     */
    function generateSenderCommitment(
        address sender,
        uint64 nonce,
        address contractAddress
    ) internal view returns (bytes32 commitment) {
        return keccak256(
            abi.encodePacked(
                sender,
                nonce,
                block.timestamp,
                block.prevrandao,
                contractAddress
            )
        );
    }

    /**
     * @notice Get shield balance
     * @param shields Mapping of commitment hashes to shield data
     * @param secret Shield secret
     * @param token Address of the token
     * @param sender Address of the user
     * @param contractAddress Address of the contract
     * @return balance Shield balance
     */
    function getShieldBalance(
        mapping(bytes32 => ITypes.Shield) storage shields,
        bytes32 secret,
        address token,
        address sender,
        address contractAddress
    ) external view returns (uint256 balance) {
        bytes32 commitment = keccak256(
            abi.encodePacked(secret, sender, block.timestamp, block.prevrandao, contractAddress)
        );
        
        ITypes.Shield storage shield = shields[commitment];
        if (ShieldFlags.getExists(shield.flags) && !ShieldFlags.getSpent(shield.flags) && shield.token == token) {
            return shield.amount;
        }
        
        return 0;
    }

    /**
     * @notice Check if commitment is active
     * @param shields Mapping of commitment hashes to shield data
     * @param commitment Commitment to check
     * @return true if shield is active
     */
    function isCommitmentActive(
        mapping(bytes32 => ITypes.Shield) storage shields,
        bytes32 commitment
    ) external view returns (bool) {
        ITypes.Shield storage shield = shields[commitment];
        return ShieldFlags.getExists(shield.flags) && !ShieldFlags.getSpent(shield.flags);
    }

    /**
     * @notice Get shield information
     * @param shields Mapping of commitment hashes to shield data
     * @param commitment Shield commitment
     * @return exists Flag indicating if shield exists
     * @return token Address of the token
     * @return amount Amount of tokens
     * @return timestamp Creation time
     * @return spent Flag indicating if shield is spent
     */
    function getShieldInfo(
        mapping(bytes32 => ITypes.Shield) storage shields,
        bytes32 commitment
    ) external view returns (
        bool exists,
        address token,
        uint256 amount,
        uint256 timestamp,
        bool spent
    ) {
        ITypes.Shield storage shield = shields[commitment];
        exists = ShieldFlags.getExists(shield.flags);
        token = shield.token;
        amount = shield.amount;
        timestamp = shield.timestamp;
        spent = ShieldFlags.getSpent(shield.flags);
    }
}