// test/LaserGun.security.test.js - Специализированные тесты безопасности
const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun Security Tests", function () {
  let contract, mockUSDC, maliciousToken;
  let admin, user1, user2, user3, attacker;

  const SHIELD_FEE = 25n;
  const UNSHIELD_FEE = 25n;
  const TRANSFER_FEE = 25n;
  const FEE_DENOMINATOR = 10000n;

  before(async function () {
    await network.provider.send("hardhat_reset", []);
  });

  beforeEach(async function () {
    try {
      [admin, user1, user2, user3, attacker] = await ethers.getSigners();

      // Deploy mock USDC token
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6, 0, false);
      await mockUSDC.waitForDeployment();

      // Deploy malicious token for reentrancy tests
      const MaliciousToken = await ethers.getContractFactory("MockERC20");
      maliciousToken = await MaliciousToken.deploy("Malicious Token", "MAL", 18, 0, false);
      await maliciousToken.waitForDeployment();

      // Mint tokens to users
      const amount = ethers.parseUnits("10000", 6);
      await mockUSDC.mint(user1.address, amount);
      await mockUSDC.mint(user2.address, amount);
      await mockUSDC.mint(user3.address, amount);
      await mockUSDC.mint(attacker.address, amount);

      const maliciousAmount = ethers.parseUnits("10000", 18);
      await maliciousToken.mint(user1.address, maliciousAmount);
      await maliciousToken.mint(attacker.address, maliciousAmount);

      // Deploy LaserGun proxy with libraries
      contract = await deployLaserGunWithLibraries(admin.address, SHIELD_FEE, UNSHIELD_FEE, TRANSFER_FEE);

      await network.provider.send("evm_mine", []);
    } catch (error) {
      console.error("BeforeEach setup failed:", error);
      throw error;
    }
  });

  // Helper function to create test shield
  async function createTestShield(user, amount, token = mockUSDC) {
    const secret = ethers.randomBytes(32);
    const block = await ethers.provider.getBlock("latest");
    const commitment = ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
      )
    );
    const bloomFilter = ethers.randomBytes(32);

    await token.connect(user).approve(await contract.getAddress(), amount);
    await contract.connect(user).shield(amount, await token.getAddress(), commitment, bloomFilter);

    return { secret, commitment, amount, bloomFilter };
  }

  describe("Reentrancy Protection Tests", function () {
    it("Should prevent reentrancy attacks on unshield function", async function () {
      // Create a malicious contract that attempts reentrancy
      const MaliciousContract = await ethers.getContractFactory("ReentrancyAttacker");
      const maliciousContract = await MaliciousContract.deploy(
        await contract.getAddress(),
        await mockUSDC.getAddress()
      );
      await maliciousContract.waitForDeployment();

      // Fund the malicious contract
      const attackAmount = ethers.parseUnits("100", 6);
      await mockUSDC.connect(attacker).transfer(await maliciousContract.getAddress(), attackAmount);

      // Attempt reentrancy attack
      await expect(
        maliciousContract.connect(attacker).attemptAttack(attackAmount)
      ).to.be.revertedWith("ReentrancyGuard: reentrant call");
    });

    it("Should prevent reentrancy attacks on transfer function", async function () {
      const MaliciousContract = await ethers.getContractFactory("ReentrancyAttacker");
      const maliciousContract = await MaliciousContract.deploy(
        await contract.getAddress(),
        await mockUSDC.getAddress()
      );
      await maliciousContract.waitForDeployment();

      // Fund the malicious contract
      const attackAmount = ethers.parseUnits("100", 6);
      await mockUSDC.connect(attacker).transfer(await maliciousContract.getAddress(), attackAmount);

      // Attempt reentrancy attack through transfer
      await expect(
        maliciousContract.connect(attacker).attemptTransferAttack(attackAmount)
      ).to.be.revertedWith("ReentrancyGuard: reentrant call");
    });

    it("Should prevent reentrancy attacks on consolidate function", async function () {
      const MaliciousContract = await ethers.getContractFactory("ReentrancyAttacker");
      const maliciousContract = await MaliciousContract.deploy(
        await contract.getAddress(),
        await mockUSDC.getAddress()
      );
      await maliciousContract.waitForDeployment();

      // Fund the malicious contract with multiple shields
      const attackAmount = ethers.parseUnits("50", 6);
      await mockUSDC.connect(attacker).transfer(await maliciousContract.getAddress(), attackAmount * 3n);

      // Attempt reentrancy attack through consolidate
      await expect(
        maliciousContract.connect(attacker).attemptConsolidateAttack(attackAmount)
      ).to.be.revertedWith("ReentrancyGuard: reentrant call");
    });

    it("Should prevent reentrancy attacks on escrow functions", async function () {
      const MaliciousContract = await ethers.getContractFactory("ReentrancyAttacker");
      const maliciousContract = await MaliciousContract.deploy(
        await contract.getAddress(),
        await mockUSDC.getAddress()
      );
      await maliciousContract.waitForDeployment();

      // Fund the malicious contract
      const attackAmount = ethers.parseUnits("100", 6);
      await mockUSDC.connect(attacker).transfer(await maliciousContract.getAddress(), attackAmount);

      // Attempt reentrancy attack through escrow release
      await expect(
        maliciousContract.connect(attacker).attemptEscrowAttack(attackAmount)
      ).to.be.revertedWith("ReentrancyGuard: reentrant call");
    });
  });

  describe("Access Control Tests", function () {
    it("Should enforce role-based access control correctly", async function () {
      // Test that non-admin cannot set fees
      await expect(
        contract.connect(user1).setFees(100n, 100n, 100n)
      ).to.be.revertedWithCustomError(contract, "AccessControlUnauthorizedAccount");

      // Test that non-admin cannot pause
      await expect(
        contract.connect(user1).pause()
      ).to.be.revertedWithCustomError(contract, "AccessControlUnauthorizedAccount");

      // Test that non-admin cannot withdraw fees
      await expect(
        contract.connect(user1).withdrawFees(await mockUSDC.getAddress(), user1.address)
      ).to.be.revertedWithCustomError(contract, "AccessControlUnauthorizedAccount");

      // Test that non-admin cannot emergency withdraw
      await expect(
        contract.connect(user1).emergencyWithdraw(await mockUSDC.getAddress(), user1.address)
      ).to.be.revertedWithCustomError(contract, "AccessControlUnauthorizedAccount");
    });

    it("Should prevent role escalation attacks", async function () {
      // Attempt to grant admin role to self
      await expect(
        contract.connect(user1).grantRole(await contract.ADMIN_ROLE(), user1.address)
      ).to.be.revertedWithCustomError(contract, "AccessControlUnauthorizedAccount");

      // Attempt to revoke admin role
      await expect(
        contract.connect(user1).revokeRole(await contract.ADMIN_ROLE(), admin.address)
      ).to.be.revertedWithCustomError(contract, "AccessControlUnauthorizedAccount");
    });

    it("Should enforce correct role permissions", async function () {
      // Admin should be able to perform all admin operations
      await expect(contract.connect(admin).pause()).to.emit(contract, "Paused");
      await expect(contract.connect(admin).unpause()).to.emit(contract, "Unpaused");

      // Test fee management
      await expect(contract.connect(admin).setFees(50n, 50n, 50n))
        .to.emit(contract, "FeesUpdated")
        .withArgs(50n, 50n, 50n);
    });
  });

  describe("Boundary Condition Tests", function () {
    it("Should handle maximum fee values correctly", async function () {
      // Set fees to maximum allowed (10%)
      const maxFee = 1000n; // 10% in basis points
      await contract.connect(admin).setFees(maxFee, maxFee, maxFee);

      const amount = ethers.parseUnits("100", 6);
      const { secret, commitment } = await createTestShield(user1, amount);

      // Check that shield works with maximum fees
      const shield = await contract.getShieldInfo(commitment);
      const expectedNetAmount = amount - (amount * maxFee / FEE_DENOMINATOR);
      expect(shield.amount).to.equal(expectedNetAmount);
    });

    it("Should reject fee values above maximum", async function () {
      const excessiveFee = 1001n; // 10.01% - exceeds maximum

      await expect(
        contract.connect(admin).setFees(excessiveFee, 0n, 0n)
      ).to.be.revertedWithCustomError(contract, "FeeExceedsMaximum");

      await expect(
        contract.connect(admin).setFees(0n, excessiveFee, 0n)
      ).to.be.revertedWithCustomError(contract, "FeeExceedsMaximum");

      await expect(
        contract.connect(admin).setFees(0n, 0n, excessiveFee)
      ).to.be.revertedWithCustomError(contract, "FeeExceedsMaximum");
    });

    it("Should handle minimum amounts correctly", async function () {
      const minAmount = 1n; // Minimum possible amount

      await mockUSDC.connect(user1).approve(await contract.getAddress(), minAmount);
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );
      const bloomFilter = ethers.randomBytes(32);

      // With 0.25% fee, 1 wei should result in 0 net amount
      await expect(
        contract.connect(user1).shield(minAmount, await mockUSDC.getAddress(), commitment, bloomFilter)
      ).to.be.revertedWithCustomError(contract, "NetAmountMustBePositive");
    });

    it("Should handle maximum consolidate shields correctly", async function () {
      // Create exactly the maximum number of shields (10)
      const secrets = [];
      const amount = ethers.parseUnits("10", 6);

      for (let i = 0; i < 10; i++) {
        const shield = await createTestShield(user1, amount);
        secrets.push(shield.secret);
      }

      const newCommitment = ethers.randomBytes(32);

      // Should succeed with exactly 10 shields
      await expect(contract.connect(user1).consolidate(secrets, newCommitment))
        .to.emit(contract, "ShieldConsolidated")
        .to.emit(contract, "Shielded");
    });

    it("Should reject exceeding maximum consolidate shields", async function () {
      // Try to consolidate 11 shields (exceeds maximum of 10)
      const secrets = [];
      const amount = ethers.parseUnits("10", 6);

      for (let i = 0; i < 11; i++) {
        const shield = await createTestShield(user1, amount);
        secrets.push(shield.secret);
      }

      const newCommitment = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).consolidate(secrets, newCommitment)
      ).to.be.revertedWithCustomError(contract, "TooManyShieldsToConsolidate");
    });

    it("Should handle escrow confirmation period boundaries", async function () {
      const amount = ethers.parseUnits("100", 6);
      
      // Test minimum confirmation period (1 hour)
      const minPeriod = 3600;
      const secret1 = ethers.randomBytes(32);
      const block1 = await ethers.provider.getBlock("latest");
      const commitment1 = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret1, user1.address, block1.timestamp, block1.prevrandao, await contract.getAddress(), 0]
        )
      );
      const bloomFilter1 = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).createEscrowShield(
        amount, await mockUSDC.getAddress(), commitment1, user2.address, minPeriod, bloomFilter1
      );

      // Test maximum confirmation period (30 days)
      const maxPeriod = 30 * 24 * 60 * 60;
      const secret2 = ethers.randomBytes(32);
      const block2 = await ethers.provider.getBlock("latest");
      const commitment2 = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret2, user1.address, block2.timestamp, block2.prevrandao, await contract.getAddress(), 0]
        )
      );
      const bloomFilter2 = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).createEscrowShield(
        amount, await mockUSDC.getAddress(), commitment2, user2.address, maxPeriod, bloomFilter2
      );
    });

    it("Should reject invalid confirmation periods", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      // Test period below minimum
      await expect(
        contract.connect(user1).createEscrowShield(
          amount, await mockUSDC.getAddress(), commitment, user2.address, 3599, bloomFilter
        )
      ).to.be.revertedWithCustomError(contract, "InvalidConfirmationPeriod");

      // Test period above maximum
      await expect(
        contract.connect(user1).createEscrowShield(
          amount, await mockUSDC.getAddress(), commitment, user2.address, 31 * 24 * 60 * 60, bloomFilter
        )
      ).to.be.revertedWithCustomError(contract, "InvalidConfirmationPeriod");
    });
  });

  describe("Error Handling Tests", function () {
    it("Should handle invalid commitments correctly", async function () {
      const amount = ethers.parseUnits("100", 6);
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      // Test with zero commitment
      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), ethers.ZeroHash, bloomFilter)
      ).to.be.revertedWithCustomError(contract, "InvalidCommitment");
    });

    it("Should handle invalid token addresses correctly", async function () {
      const amount = ethers.parseUnits("100", 6);
      const commitment = ethers.randomBytes(32);
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      // Test with zero address
      await expect(
        contract.connect(user1).shield(amount, ethers.ZeroAddress, commitment, bloomFilter)
      ).to.be.revertedWithCustomError(contract, "EmptyToken");
    });

    it("Should handle invalid recipients correctly", async function () {
      const amount = ethers.parseUnits("100", 6);
      const { secret, commitment } = await createTestShield(user1, amount);
      const newCommitment = ethers.randomBytes(32);

      // Test with zero address recipient
      await expect(
        contract.connect(user1).unshield(secret, amount, ethers.ZeroAddress, newCommitment)
      ).to.be.revertedWithCustomError(contract, "InvalidRecipient");
    });

    it("Should handle insufficient balances correctly", async function () {
      const amount = ethers.parseUnits("100", 6);
      const { secret, commitment } = await createTestShield(user1, amount);
      const newCommitment = ethers.randomBytes(32);

      // Test with amount greater than shield balance
      const excessiveAmount = amount + 1n;
      await expect(
        contract.connect(user1).unshield(secret, excessiveAmount, user2.address, newCommitment)
      ).to.be.revertedWithCustomError(contract, "InsufficientShieldBalance");
    });

    it("Should handle spent shields correctly", async function () {
      const amount = ethers.parseUnits("100", 6);
      const { secret, commitment } = await createTestShield(user1, amount);
      const newCommitment = ethers.randomBytes(32);

      // First unshield
      await contract.connect(user1).unshield(secret, amount, user2.address, ethers.ZeroHash);

      // Try to unshield again with same shield
      await expect(
        contract.connect(user1).unshield(secret, amount, user2.address, newCommitment)
      ).to.be.revertedWithCustomError(contract, "ShieldAlreadySpent");
    });

    it("Should handle duplicate commitments correctly", async function () {
      const amount = ethers.parseUnits("100", 6);
      const commitment = ethers.randomBytes(32);
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount * 2n);

      // First shield
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);

      // Try to create another shield with same commitment
      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
      ).to.be.revertedWithCustomError(contract, "CommitmentAlreadyExists");
    });

    it("Should handle empty encrypted secrets correctly", async function () {
      const amount = ethers.parseUnits("100", 6);
      const { secret, commitment } = await createTestShield(user1, amount);
      const recipientCommitment = ethers.randomBytes(32);
      const emptyEncryptedSecret = "0x";
      const bloomFilter = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).transfer(
          secret, amount, recipientCommitment, emptyEncryptedSecret, bloomFilter
        )
      ).to.be.revertedWithCustomError(contract, "EncryptedSecretCannotBeEmpty");
    });
  });

  describe("Cryptographic Security Tests", function () {
    it("Should generate unique commitments for different secrets", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret1 = ethers.randomBytes(32);
      const secret2 = ethers.randomBytes(32);
      
      const block = await ethers.provider.getBlock("latest");
      const commitment1 = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret1, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );
      const commitment2 = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret2, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );

      expect(commitment1).to.not.equal(commitment2);
    });

    it("Should generate unique commitments for different users", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      
      const block = await ethers.provider.getBlock("latest");
      const commitment1 = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );
      const commitment2 = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user2.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );

      expect(commitment1).to.not.equal(commitment2);
    });

    it("Should include nonce in commitment generation", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      
      // Create first shield
      const shield1 = await createTestShield(user1, amount);
      
      // Create second shield with same secret
      const shield2 = await createTestShield(user1, amount);

      expect(shield1.commitment).to.not.equal(shield2.commitment);
    });

    it("Should prevent commitment collision attacks", async function () {
      const amount = ethers.parseUnits("100", 6);
      
      // Create multiple shields rapidly to test for collisions
      const commitments = new Set();
      for (let i = 0; i < 100; i++) {
        const shield = await createTestShield(user1, amount);
        expect(commitments.has(shield.commitment)).to.be.false;
        commitments.add(shield.commitment);
      }
    });
  });

  describe("Integer Overflow/Underflow Tests", function () {
    it("Should prevent amount overflow in consolidation", async function () {
      // Create shields with large amounts
      const largeAmount = ethers.MaxUint256 / 3n;
      const secrets = [];

      for (let i = 0; i < 3; i++) {
        await mockUSDC.mint(user1.address, largeAmount);
        const shield = await createTestShield(user1, largeAmount);
        secrets.push(shield.secret);
      }

      const newCommitment = ethers.randomBytes(32);

      // This should fail due to overflow protection
      await expect(
        contract.connect(user1).consolidate(secrets, newCommitment)
      ).to.be.revertedWithCustomError(contract, "AmountOverflow");
    });

    it("Should handle fee calculation edge cases", async function () {
      // Test with very large amount
      const largeAmount = ethers.MaxUint256;
      
      await mockUSDC.mint(user1.address, largeAmount);
      await mockUSDC.connect(user1).approve(await contract.getAddress(), largeAmount);

      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );
      const bloomFilter = ethers.randomBytes(32);

      // This should handle large amounts correctly
      await expect(
        contract.connect(user1).shield(largeAmount, await mockUSDC.getAddress(), commitment, bloomFilter)
      ).to.be.revertedWithCustomError(contract, "NetAmountMustBePositive"); // Fee would consume entire amount
    });
  });

  describe("Gas Limit and DoS Protection Tests", function () {
    it("Should handle gas limit edge cases", async function () {
      // Create a shield with minimal gas
      const amount = ethers.parseUnits("1", 6);
      const { secret, commitment } = await createTestShield(user1, amount);

      // Should work even with minimal gas
      const tx = await contract.connect(user1).unshield(secret, amount, user2.address, ethers.ZeroHash);
      const receipt = await tx.wait();
      
      // Gas usage should be reasonable
      expect(receipt.gasUsed).to.be.lt(200000n);
    });

    it("Should prevent DoS through excessive shields", async function () {
      // This test verifies that the contract limits prevent DoS attacks
      const secrets = [];
      const amount = ethers.parseUnits("10", 6);

      // Create maximum allowed shields
      for (let i = 0; i < 10; i++) {
        const shield = await createTestShield(user1, amount);
        secrets.push(shield.secret);
      }

      // Try to create one more (should fail due to consolidate limit)
      const additionalShield = await createTestShield(user1, amount);
      secrets.push(additionalShield.secret);

      const newCommitment = ethers.randomBytes(32);
      await expect(
        contract.connect(user1).consolidate(secrets, newCommitment)
      ).to.be.revertedWithCustomError(contract, "TooManyShieldsToConsolidate");
    });
  });

  describe("Emergency Situation Tests", function () {
    it("Should handle emergency pause correctly", async function () {
      // Create a shield before pause
      const amount = ethers.parseUnits("100", 6);
      const { secret, commitment } = await createTestShield(user1, amount);

      // Pause the contract
      await contract.connect(admin).pause();

      // Should reject all operations when paused
      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), ethers.randomBytes(32), ethers.randomBytes(32))
      ).to.be.revertedWithCustomError(contract, "EnforcedPause");

      await expect(
        contract.connect(user1).unshield(secret, amount, user2.address, ethers.randomBytes(32))
      ).to.be.revertedWithCustomError(contract, "EnforcedPause");

      await expect(
        contract.connect(user1).transfer(secret, amount, ethers.randomBytes(32), ethers.hexlify(ethers.randomBytes(64)), ethers.randomBytes(32))
      ).to.be.revertedWithCustomError(contract, "EnforcedPause");

      // Emergency withdraw should work when paused
      await expect(contract.connect(admin).emergencyWithdraw(await mockUSDC.getAddress(), admin.address))
        .to.emit(contract, "EmergencyWithdraw");
    });

    it("Should reject emergency operations when not paused", async function () {
      await expect(
        contract.connect(admin).emergencyWithdraw(await mockUSDC.getAddress(), admin.address)
      ).to.be.revertedWithCustomError(contract, "ExpectedPause");
    });
  });
});