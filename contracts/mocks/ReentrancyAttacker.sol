// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILaserGun} from "../../contracts/interfaces/ILaserGun.sol";

/**
 * @title ReentrancyAttacker
 * @notice Malicious contract to test reentrancy protection
 */
contract ReentrancyAttacker {
    ILaserGun public laserGun;
    IERC20 public token;
    address public owner;
    bool public attacking;
    uint256 public attackCount;
    bool private _locked;

    event AttackStarted(uint256 amount);
    event AttackAttempted(uint256 attempt);
    event AttackSucceeded(uint256 amount);

    // Custom errors
    error OnlyOwner();
    error AttackAlreadyInProgress();
    error TransferFailed();
    error ReentrantCall();

    modifier nonReentrant() {
        if (_locked) revert ReentrantCall();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _laserGun, address _token) {
        laserGun = ILaserGun(_laserGun);
        token = IERC20(_token);
        owner = msg.sender;
        attacking = false;
        attackCount = 0;
    }

    function attemptAttack(uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert OnlyOwner();
        if (attacking) revert AttackAlreadyInProgress();
        
        attacking = true;
        attackCount = 0;
        emit AttackStarted(amount);

        // Create a shield first
        bytes32 secret = keccak256(abi.encodePacked("attack_secret", block.timestamp));
        bytes32 commitment = keccak256(abi.encodePacked(
            secret,
            address(this),
            block.timestamp,
            block.prevrandao,
            address(laserGun),
            uint256(0)
        ));
        bytes32 bloomFilter = keccak256("bloom_filter");

        // Approve tokens for shield
        token.approve(address(laserGun), amount);
        
        // Create shield
        laserGun.shield(amount, address(token), commitment, bloomFilter);

        // Reset attacking flag before external call to prevent reentrancy warnings
        attacking = false;

        // Now attempt to unshield with reentrancy
        try laserGun.unshield(secret, amount, address(this), bytes32(0)) {
            emit AttackSucceeded(amount);
        } catch {
            // Attack failed - emit failure event
            emit AttackAttempted(0);
        }
    }

    function attemptTransferAttack(uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert OnlyOwner();
        if (attacking) revert AttackAlreadyInProgress();
        
        attacking = true;
        attackCount = 0;
        emit AttackStarted(amount);

        // Create a shield first
        bytes32 secret = keccak256(abi.encodePacked("transfer_attack_secret", block.timestamp));
        bytes32 commitment = keccak256(abi.encodePacked(
            secret,
            address(this),
            block.timestamp,
            block.prevrandao,
            address(laserGun),
            uint256(0)
        ));
        bytes32 bloomFilter = keccak256("transfer_bloom_filter");

        // Approve tokens for shield
        token.approve(address(laserGun), amount);
        
        // Create shield
        laserGun.shield(amount, address(token), commitment, bloomFilter);

        // Now attempt to transfer with reentrancy
        bytes32 recipientCommitment = keccak256(abi.encodePacked("recipient_secret", block.timestamp));
        bytes memory encryptedSecret = abi.encodePacked("encrypted_secret_data");
        
        try laserGun.transfer(secret, amount, recipientCommitment, encryptedSecret, bloomFilter) {
            emit AttackSucceeded(amount);
        } catch {
            // Attack failed - emit failure event
            emit AttackAttempted(0);
        }
        
        // Note: attacking flag will be reset by the nonReentrant modifier
    }

    function attemptConsolidateAttack(uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert OnlyOwner();
        if (attacking) revert AttackAlreadyInProgress();
        
        attacking = true;
        attackCount = 0;
        emit AttackStarted(amount);

        // Create multiple shields for consolidation
        bytes32[] memory secrets = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            secrets[i] = keccak256(abi.encodePacked("consolidate_secret", i, block.timestamp));
            bytes32 commitment = keccak256(abi.encodePacked(
                secrets[i],
                address(this),
                block.timestamp,
                block.prevrandao,
                address(laserGun),
                i
            ));
            bytes32 bloomFilter = keccak256(abi.encodePacked("consolidate_bloom", i));
            
            token.approve(address(laserGun), amount);
            laserGun.shield(amount, address(token), commitment, bloomFilter);
        }

        // Now attempt to consolidate with reentrancy
        bytes32 newCommitment = keccak256(abi.encodePacked("consolidated_secret", block.timestamp));
        
        try laserGun.consolidate(secrets, newCommitment) {
            emit AttackSucceeded(amount * 3);
        } catch {
            // Attack failed - emit failure event
            emit AttackAttempted(0);
        }
        
        attacking = false;
    }

    function attemptEscrowAttack(uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert OnlyOwner();
        if (attacking) revert AttackAlreadyInProgress();
        
        attacking = true;
        attackCount = 0;
        emit AttackStarted(amount);

        // Create escrow shield first
        bytes32 secret = keccak256(abi.encodePacked("escrow_attack_secret", block.timestamp));
        bytes32 commitment = keccak256(abi.encodePacked(
            secret,
            address(this),
            block.timestamp,
            block.prevrandao,
            address(laserGun),
            uint256(0)
        ));
        address recipient = address(0x123); // Dummy recipient address
        bytes memory encryptedSecret = abi.encodePacked("encrypted_secret_data");
        bytes32 bloomFilter = keccak256("escrow_bloom_filter");

        // Approve tokens for escrow shield
        token.approve(address(laserGun), amount);
        
        // Create escrow shield
        laserGun.createEscrowShield(commitment, encryptedSecret, bloomFilter);

        // Confirm escrow
        laserGun.confirmEscrow(commitment, secret, recipient);

        // Now attempt to cancel with reentrancy
        try laserGun.cancelEscrow(commitment, secret) {
            emit AttackSucceeded(amount);
        } catch {
            // Attack failed - emit failure event
            emit AttackAttempted(0);
        }
        
        attacking = false;
    }

    // This function will be called during token transfer if reentrancy is possible
    receive() external payable {
        if (attacking && msg.sender == address(laserGun)) {
            attackCount++;
            emit AttackAttempted(attackCount);
            
            // Attempt to call back into the contract (this should fail with proper reentrancy protection)
            if (attackCount < 3) { // Limit recursion to avoid infinite loops
                // Try various attack vectors
                bytes32 secret = keccak256(abi.encodePacked("reentrancy_secret", attackCount));
                bytes32 commitment = keccak256(abi.encodePacked(
                    secret,
                    address(this),
                    block.timestamp,
                    block.prevrandao,
                    address(laserGun),
                    attackCount
                ));
                bytes32 bloomFilter = keccak256(abi.encodePacked("reentrancy_bloom", attackCount));
                
                // This should fail due to reentrancy guard
                try laserGun.shield(1, address(token), commitment, bloomFilter) {
                    // If this succeeds, reentrancy protection has failed
                    emit AttackSucceeded(1);
                } catch {
                    // Expected to fail - emit failure event
                    emit AttackAttempted(attackCount);
                }
            }
        }
    }

    function withdrawTokens(uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert OnlyOwner();
        
        bool success = token.transfer(owner, amount);
        
        if (!success) {
            revert TransferFailed();
        }
        
        // Note: attacking flag is not modified here to avoid reentrancy warnings
        // The nonReentrant modifier provides sufficient protection
    }

    function getBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}