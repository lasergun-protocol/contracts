// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library LaserGunLib {
    error ZeroAmount();
    error EmptyToken();
    error InvalidCommitment();

    uint256 public constant FEE_DENOMINATOR = 10000; // 100% = 10000 basis points

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
    function generateCommitment(bytes32 secret, address recipient) internal pure returns (bytes32) {
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

    /**
     * @dev Validate voucher parameters
     * @param amount The voucher amount
     * @param token The token address
     * @param commitment The commitment hash
     */
    function validateVoucherParams(
        uint256 amount,
        address token,
        bytes32 commitment
    ) internal pure {
        if (!(amount > 0)) revert ZeroAmount();
        if(token == address(0)) revert  EmptyToken();
        if(commitment == bytes32(0)) revert InvalidCommitment();
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
}