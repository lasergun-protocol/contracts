// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @author LaserGun Team
 * @notice Unified mock ERC20 token for testing and deployment
 * @dev Simplified ERC20 token with functions for both local testing and testnet deployment
 *
 * Features:
 * - Support for custom decimals
 * - Mint function for creating tokens (public for testing, owner for production)
 * - Burn function for destroying tokens
 * - Optional initial supply at deployment
 * - Simple and lightweight implementation
 *
 * Usage:
 * - In unit tests (with public mint)
 * - In testnet deployments (with owner-controlled mint)
 * - To simulate different tokens (USDC, DAI, etc.)
 */
contract MockERC20 is ERC20 {
    /// @notice Number of decimal places for the token
    uint8 private _decimals;
    
    /// @notice Contract owner for production deployments
    address public owner;

    /// @notice Event emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // Custom errors
    error OnlyOwnerCanMint();
    error UnauthorizedBurn();
    error OwnershipNotEnabled();
    error OnlyOwnerCanTransfer();
    error NewOwnerIsZeroAddress();
    error OnlyOwnerCanUseFaucet();

    /**
     * @notice Constructor for the mock token
     * @dev Creates a new ERC20 token with specified parameters
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param decimals_ Number of decimal places
     * @param initialSupply Initial token supply (0 for testing, >0 for testnet)
     * @param setOwnership Whether to set ownership (true for testnet, false for testing)
     *
     * Effects:
     * - Sets the token name and symbol
     * - Stores the number of decimals
     * - Sets initial supply if provided
     * - Sets ownership if requested
     */
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 initialSupply,
        bool setOwnership
    ) ERC20(name, symbol) {
        _decimals = decimals_;
        
        if (setOwnership) {
            owner = msg.sender;
            emit OwnershipTransferred(address(0), msg.sender);
        }
        
        // Mint initial supply to deployer if specified
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply * 10 ** decimals_);
        }
    }

    /**
     * @notice Returns the number of decimal places for the token
     * @dev Overrides the standard ERC20 function
     * @return Number of decimal places
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Create new tokens
     * @dev Mints the specified amount of tokens to the recipient address
     * @param to Address of the token recipient
     * @param amount Amount of tokens to create
     *
     * Requirements:
     * - to must be a valid address
     * - amount must be greater than 0
     *
     * Effects:
     * - Increases total supply
     * - Increases recipient balance
     * - Emits Transfer event
     *
     * Security:
     * - Public when no owner is set (testing mode)
     * - Owner-only when ownership is set (production mode)
     */
    function mint(address to, uint256 amount) external {
        if (owner != address(0)) {
            if (msg.sender != owner) revert OnlyOwnerCanMint();
        }
        _mint(to, amount);
    }

    /**
     * @notice Destroy tokens
     * @dev Burns the specified amount of tokens from the specified address
     * @param from Address from which tokens are burned
     * @param amount Amount of tokens to destroy
     *
     * Requirements:
     * - from must have sufficient balance
     * - amount must be greater than 0
     * - msg.sender must be owner or from address
     *
     * Effects:
     * - Decreases total supply
     * - Decreases from balance
     * - Emits Transfer event
     */
    function burn(address from, uint256 amount) external {
        if (!(msg.sender == from || (owner != address(0) && msg.sender == owner))) revert UnauthorizedBurn();
        _burn(from, amount);
    }

    /**
     * @notice Transfer ownership to a new address
     * @dev Only available when ownership is enabled
     * @param newOwner Address of the new owner
     */
    function transferOwnership(address newOwner) external {
        if (owner == address(0)) revert OwnershipNotEnabled();
        if (msg.sender != owner) revert OnlyOwnerCanTransfer();
        if (newOwner == address(0)) revert NewOwnerIsZeroAddress();
        
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @notice Simple faucet function for testnet deployments
     * @dev Only available when ownership is enabled and called by owner
     * @param to Address to receive faucet tokens
     * @param amount Amount of tokens to send
     */
    function faucet(address to, uint256 amount) external {
        if (owner == address(0)) revert OwnershipNotEnabled();
        if (msg.sender != owner) revert OnlyOwnerCanUseFaucet();
        _mint(to, amount);
    }
}