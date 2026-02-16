// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ITypes
 * @author LaserGun Team
 * @notice Library containing common type definitions for LaserGun contracts
 */
library ITypes {
    /**
     * @notice Shield structure for storing private tokens
     * @dev Contains all necessary information about a shield
     * @param token Address of the ERC20 token
     * @param amount Amount of tokens in the shield
     * @param timestamp Shield creation time
     * @param flags Packed boolean flags: bit 0 = exists, bit 1 = spent, bit 2 = isEscrow
     */
    struct Shield {
        address token;
        uint256 amount;
        uint64 timestamp;  // Optimized from uint256, covers dates until 2106
        uint8 flags;       // Packing boolean flags: bit 0 = exists, bit 1 = spent, bit 2 = isEscrow
    }

    /**
     * @notice Simple Escrow structure
     * @dev Contains escrow-specific information
     * @param commitment Reference to the shield commitment
     * @param timestamp Creation timestamp
     * @param confirmationDeadline Timestamp until when sender must confirm
     * @param creator Address of the escrow creator
     * @param prevrandao Block prevrandao value at creation time (for commitment verification)
     * @param creatorNonce User nonce at the time of escrow creation (for commitment verification)
     */
    struct Escrow {
        bytes32 commitment;
        uint64 timestamp;
        uint64 confirmationDeadline;
        address creator;
        bytes32 prevrandao;
        uint64 creatorNonce;
    }
}