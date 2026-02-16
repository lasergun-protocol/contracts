// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ShieldFlags
 * @author Ilya  A. Shlyakhovoy
 * @notice Library for working with packed flags for shield states
 * @dev Provides efficient bit manipulation operations for shield status tracking
 */
library ShieldFlags {
    uint8 private constant EXISTS_FLAG = 1 << 0;
    uint8 private constant SPENT_FLAG = 1 << 1;
    uint8 private constant IS_ESCROW_FLAG = 1 << 2;
    uint8 private constant CONFIRMED_FLAG = 1 << 3;
    uint8 private constant RELEASED_FLAG = 1 << 4;
    uint8 private constant CANCELLED_FLAG = 1 << 5;
    
    /**
     * @notice Sets the EXISTS flag
     * @param flags Current flags value
     * @param value Boolean value to set
     * @return Updated flags value
     */
    function setExists(uint8 flags, bool value) internal pure returns (uint8) {
        return value ? flags | EXISTS_FLAG : flags & ~EXISTS_FLAG;
    }
    
    /**
     * @notice Sets the SPENT flag
     * @param flags Current flags value
     * @param value Boolean value to set
     * @return Updated flags value
     */
    function setSpent(uint8 flags, bool value) internal pure returns (uint8) {
        return value ? flags | SPENT_FLAG : flags & ~SPENT_FLAG;
    }
    
    /**
     * @notice Sets the IS_ESCROW flag
     * @param flags Current flags value
     * @param value Boolean value to set
     * @return Updated flags value
     */
    function setIsEscrow(uint8 flags, bool value) internal pure returns (uint8) {
        return value ? flags | IS_ESCROW_FLAG : flags & ~IS_ESCROW_FLAG;
    }
    
    /**
     * @notice Sets the CONFIRMED flag
     * @param flags Current flags value
     * @param value Boolean value to set
     * @return Updated flags value
     */
    function setConfirmed(uint8 flags, bool value) internal pure returns (uint8) {
        return value ? flags | CONFIRMED_FLAG : flags & ~CONFIRMED_FLAG;
    }
    
    /**
     * @notice Sets the RELEASED flag
     * @param flags Current flags value
     * @param value Boolean value to set
     * @return Updated flags value
     */
    function setReleased(uint8 flags, bool value) internal pure returns (uint8) {
        return value ? flags | RELEASED_FLAG : flags & ~RELEASED_FLAG;
    }
    
    /**
     * @notice Sets the CANCELLED flag
     * @param flags Current flags value
     * @param value Boolean value to set
     * @return Updated flags value
     */
    function setCancelled(uint8 flags, bool value) internal pure returns (uint8) {
        return value ? flags | CANCELLED_FLAG : flags & ~CANCELLED_FLAG;
    }
    
    /**
     * @notice Gets the EXISTS flag value
     * @param flags Current flags value
     * @return Boolean value of the EXISTS flag
     */
    function getExists(uint8 flags) internal pure returns (bool) {
        return (flags & EXISTS_FLAG) != 0;
    }
    
    /**
     * @notice Gets the SPENT flag value
     * @param flags Current flags value
     * @return Boolean value of the SPENT flag
     */
    function getSpent(uint8 flags) internal pure returns (bool) {
        return (flags & SPENT_FLAG) != 0;
    }
    
    /**
     * @notice Gets the IS_ESCROW flag value
     * @param flags Current flags value
     * @return Boolean value of the IS_ESCROW flag
     */
    function getIsEscrow(uint8 flags) internal pure returns (bool) {
        return (flags & IS_ESCROW_FLAG) != 0;
    }
    
    /**
     * @notice Gets the CONFIRMED flag value
     * @param flags Current flags value
     * @return Boolean value of the CONFIRMED flag
     */
    function getConfirmed(uint8 flags) internal pure returns (bool) {
        return (flags & CONFIRMED_FLAG) != 0;
    }
    
    /**
     * @notice Gets the RELEASED flag value
     * @param flags Current flags value
     * @return Boolean value of the RELEASED flag
     */
    function getReleased(uint8 flags) internal pure returns (bool) {
        return (flags & RELEASED_FLAG) != 0;
    }
    
    /**
     * @notice Gets the CANCELLED flag value
     * @param flags Current flags value
     * @return Boolean value of the CANCELLED flag
     */
    function getCancelled(uint8 flags) internal pure returns (bool) {
        return (flags & CANCELLED_FLAG) != 0;
    }
}