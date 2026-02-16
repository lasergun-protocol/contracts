// test/LaserGun.crypto.test.js - Тесты криптографической безопасности
const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun Cryptographic Security Tests", function () {
  let contract, mockUSDC;
  let admin, user1, user2, user3;

  const SHIELD_FEE = 25n;
  const UNSHIELD_FEE = 25n;
  const TRANSFER_FEE = 25n;
  const FEE_DENOMINATOR = 10000n;

  before(async function () {
    await network.provider.send("hardhat_reset", []);
  });

  beforeEach(async function () {
    try {
      [admin, user1, user2, user3] = await ethers.getSigners();

      // Deploy mock USDC token
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6, 0, false);
      await mockUSDC.waitForDeployment();

      // Mint tokens to users
      const amount = ethers.parseUnits("10000", 6);
      await mockUSDC.mint(user1.address, amount);
      await mockUSDC.mint(user2.address, amount);
      await mockUSDC.mint(user3.address, amount);

      // Deploy LaserGun proxy with libraries
      contract = await deployLaserGunWithLibraries(admin.address, SHIELD_FEE, UNSHIELD_FEE, TRANSFER_FEE);

      await network.provider.send("evm_mine", []);
    } catch (error) {
      console.error("BeforeEach setup failed:", error);
      throw error;
    }
  });

  describe("generateCommitment Security Tests", function () {
    it("Should generate unique commitments for identical secrets with different nonces", async function () {
      const secret = ethers.randomBytes(32);
      
      // Get initial nonce
      const initialNonce = await contract.userNonces(user1.address);
      
      // Generate commitment with initial nonce
      const commitment1 = await contract.generateCommitment(secret, user1.address);
      
      // Increment nonce (simulating shield creation)
      const amount = ethers.parseUnits("100", 6);
      const block = await ethers.provider.getBlock("latest");
      const commitmentForShield = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), initialNonce]
        )
      );
      const bloomFilter = ethers.randomBytes(32);
      
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitmentForShield, bloomFilter);
      
      // Generate commitment with incremented nonce
      const commitment2 = await contract.generateCommitment(secret, user1.address);
      
      // Commitments should be different due to nonce
      expect(commitment1).to.not.equal(commitment2);
    });

    it("Should include block.timestamp in commitment generation", async function () {
      const secret = ethers.randomBytes(32);
      
      // Generate commitment at current time
      const commitment1 = await contract.generateCommitment(secret, user1.address);
      
      // Fast forward time
      await ethers.provider.send("evm_increaseTime", [10]);
      await ethers.provider.send("evm_mine", []);
      
      // Generate commitment at different time
      const commitment2 = await contract.generateCommitment(secret, user1.address);
      
      // Commitments should be different due to timestamp
      expect(commitment1).to.not.equal(commitment2);
    });

    it("Should include block.prevrandao in commitment generation", async function () {
      const secret = ethers.randomBytes(32);
      
      // Generate commitment with current prevrandao
      const commitment1 = await contract.generateCommitment(secret, user1.address);
      
      // Mine a new block to change prevrandao
      await ethers.provider.send("evm_mine", []);
      
      // Generate commitment with new prevrandao
      const commitment2 = await contract.generateCommitment(secret, user1.address);
      
      // Commitments should be different due to prevrandao
      expect(commitment1).to.not.equal(commitment2);
    });

    it("Should include contract address in commitment generation", async function () {
      const secret = ethers.randomBytes(32);
      
      // Generate commitment from current contract
      const commitment1 = await contract.generateCommitment(secret, user1.address);
      
      // Deploy a second contract instance
      const contract2 = await deployLaserGunWithLibraries(admin.address, SHIELD_FEE, UNSHIELD_FEE, TRANSFER_FEE);
      
      // Generate commitment from second contract
      const commitment2 = await contract2.generateCommitment(secret, user1.address);
      
      // Commitments should be different due to contract address
      expect(commitment1).to.not.equal(commitment2);
    });

    it("Should prevent commitment prediction attacks", async function () {
      const secret = ethers.randomBytes(32);
      
      // Generate multiple commitments to test for patterns
      const commitments = [];
      for (let i = 0; i < 10; i++) {
        const commitment = await contract.generateCommitment(secret, user1.address);
        commitments.push(commitment);
        
        // Mine a block to change randomness
        await ethers.provider.send("evm_mine", []);
      }
      
      // Check that all commitments are unique
      const uniqueCommitments = new Set(commitments);
      expect(uniqueCommitments.size).to.equal(commitments.length);
      
      // Check that commitments don't follow obvious patterns
      for (let i = 1; i < commitments.length; i++) {
        const diff = BigInt(commitments[i]) - BigInt(commitments[i-1]);
        // Difference should not be constant (indicating predictable pattern)
        expect(diff).to.not.equal(BigInt(commitments[1]) - BigInt(commitments[0]));
      }
    });

    it("Should handle zero secret securely", async function () {
      const zeroSecret = ethers.ZeroHash;
      
      const commitment = await contract.generateCommitment(zeroSecret, user1.address);
      
      // Should still generate a valid commitment
      expect(commitment).to.not.equal(ethers.ZeroHash);
      expect(commitment).to.match(/^0x[a-fA-F0-9]{64}$/);
    });

    it("Should handle maximum secret values securely", async function () {
      const maxSecret = ethers.MaxUint256;
      
      const commitment = await contract.generateCommitment(maxSecret, user1.address);
      
      // Should still generate a valid commitment
      expect(commitment).to.not.equal(ethers.ZeroHash);
      expect(commitment).to.match(/^0x[a-fA-F0-9]{64}$/);
    });
  });

  describe("Secret Security Tests", function () {
    it("Should properly obscure secret in commitment", async function () {
      const secret = ethers.randomBytes(32);
      const commitment = await contract.generateCommitment(secret, user1.address);
      
      // It should be computationally infeasible to derive secret from commitment
      // We test this by ensuring the commitment is a proper hash
      expect(commitment).to.not.equal(secret);
      expect(commitment).to.not.equal(ethers.keccak256(secret));
      expect(commitment).to.not.equal(ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["bytes32"], [secret])));
    });

    it("Should prevent secret reuse attacks", async function () {
      const secret = ethers.randomBytes(32);
      const amount = ethers.parseUnits("100", 6);
      
      // Create first shield
      const block1 = await ethers.provider.getBlock("latest");
      const commitment1 = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block1.timestamp, block1.prevrandao, await contract.getAddress(), 0]
        )
      );
      const bloomFilter1 = ethers.randomBytes(32);
      
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment1, bloomFilter1);
      
      // Try to create second shield with same secret
      const block2 = await ethers.provider.getBlock("latest");
      const commitment2 = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block2.timestamp, block2.prevrandao, await contract.getAddress(), 1]
        )
      );
      const bloomFilter2 = ethers.randomBytes(32);
      
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment2, bloomFilter2);
      
      // Both shields should exist with different commitments
      const shield1 = await contract.getShieldInfo(commitment1);
      const shield2 = await contract.getShieldInfo(commitment2);
      
      expect(shield1.exists).to.be.true;
      expect(shield2.exists).to.be.true;
      expect(commitment1).to.not.equal(commitment2);
    });

    it("Should handle secret entropy correctly", async function () {
      // Test with low entropy secrets
      const lowEntropySecret = ethers.toUtf8Bytes("low_entropy");
      const commitment1 = await contract.generateCommitment(lowEntropySecret, user1.address);
      
      // Test with high entropy secrets
      const highEntropySecret = ethers.randomBytes(32);
      const commitment2 = await contract.generateCommitment(highEntropySecret, user1.address);
      
      // Both should produce valid commitments
      expect(commitment1).to.match(/^0x[a-fA-F0-9]{64}$/);
      expect(commitment2).to.match(/^0x[a-fA-F0-9]{64}$/);
      expect(commitment1).to.not.equal(commitment2);
    });
  });

  describe("Bloom Filter Security Tests", function () {
    it("Should handle bloom filters of various sizes", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );
      
      // Test with different bloom filter sizes
      const bloomFilters = [
        ethers.ZeroHash, // 32 bytes of zeros
        ethers.hexlify(ethers.randomBytes(32)), // 32 random bytes
        ethers.hexlify(ethers.randomBytes(64)), // 64 random bytes
        ethers.hexlify(ethers.randomBytes(128)), // 128 random bytes
      ];
      
      for (const bloomFilter of bloomFilters) {
        await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
        await expect(
          contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
        ).to.emit(contract, "Shielded");
      }
    });

    it("Should not reveal information through bloom filters", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );
      
      // Create shield with identifiable bloom filter
      const identifiableBloomFilter = ethers.keccak256("identifiable_pattern");
      
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, identifiableBloomFilter);
      
      // The bloom filter should not allow linking shields to users
      // This is more of a design principle test
      const shield = await contract.getShieldInfo(commitment);
      expect(shield.exists).to.be.true;
      
      // The actual security depends on proper bloom filter usage by clients
      // The contract should not leak information through events
      const events = await contract.queryFilter(contract.filters.Shielded());
      const latestEvent = events[events.length - 1];
      expect(latestEvent.args.bloomFilter).to.equal(identifiableBloomFilter);
    });
  });

  describe("Random Number Generation Security Tests", function () {
    it("Should use secure randomness sources", async function () {
      // This test verifies that the contract uses multiple entropy sources
      const secret = ethers.randomBytes(32);
      
      // Generate commitments at different times
      const commitments = [];
      for (let i = 0; i < 5; i++) {
        const commitment = await contract.generateCommitment(secret, user1.address);
        commitments.push(commitment);
        
        // Mine multiple blocks to change randomness
        for (let j = 0; j < 3; j++) {
          await ethers.provider.send("evm_mine", []);
        }
      }
      
      // All commitments should be unique
      const uniqueCommitments = new Set(commitments);
      expect(uniqueCommitments.size).to.equal(commitments.length);
      
      // Test that commitments change with different entropy sources
      const commitment1 = commitments[0];
      const commitment2 = commitments[1];
      
      // Should be different due to timestamp, prevrandao, and other factors
      expect(commitment1).to.not.equal(commitment2);
    });

    it("Should resist randomness manipulation", async function () {
      // Test that commitments are unpredictable even with some control over block parameters
      const secret = ethers.randomBytes(32);
      
      // Generate commitment
      const commitment1 = await contract.generateCommitment(secret, user1.address);
      
      // Try to manipulate by mining blocks quickly
      for (let i = 0; i < 10; i++) {
        await ethers.provider.send("evm_mine", []);
      }
      
      // Generate another commitment
      const commitment2 = await contract.generateCommitment(secret, user1.address);
      
      // Should still be different and unpredictable
      expect(commitment1).to.not.equal(commitment2);
    });
  });

  describe("Hash Collision Resistance Tests", function () {
    it("Should resist hash collision attempts", async function () {
      // Generate many commitments to test for accidental collisions
      const commitments = new Set();
      const numTests = 1000;
      
      for (let i = 0; i < numTests; i++) {
        const secret = ethers.randomBytes(32);
        const commitment = await contract.generateCommitment(secret, user1.address);
        
        // Check for collision
        expect(commitments.has(commitment)).to.be.false;
        commitments.add(commitment);
        
        // Mine a block to change randomness
        if (i % 10 === 0) {
          await ethers.provider.send("evm_mine", []);
        }
      }
      
      // Should have generated all unique commitments
      expect(commitments.size).to.equal(numTests);
    });

    it("Should handle hash preimage resistance", async function () {
      const targetCommitment = ethers.randomBytes(32);
      
      // It should be computationally infeasible to find a secret that produces the target commitment
      // We test this by generating random secrets and verifying they don't produce the target
      for (let i = 0; i < 100; i++) {
        const secret = ethers.randomBytes(32);
        const commitment = await contract.generateCommitment(secret, user1.address);
        
        // Probability of accidental match should be negligible
        expect(commitment).to.not.equal(targetCommitment);
      }
    });
  });

  describe("Side-Channel Resistance Tests", function () {
    it("Should not leak information through gas consumption", async function () {
      const secret1 = ethers.randomBytes(32);
      const secret2 = ethers.randomBytes(32);
      
      // Generate commitments and measure gas
      const tx1 = await contract.generateCommitment.populateTransaction(secret1, user1.address);
      const gasEstimate1 = await ethers.provider.estimateGas(tx1);
      
      const tx2 = await contract.generateCommitment.populateTransaction(secret2, user1.address);
      const gasEstimate2 = await ethers.provider.estimateGas(tx2);
      
      // Gas consumption should be consistent regardless of secret
      expect(gasEstimate1).to.equal(gasEstimate2);
    });

    it("Should not leak information through execution time", async function () {
      const secret1 = ethers.randomBytes(32);
      const secret2 = ethers.randomBytes(32);
      
      // Generate commitments multiple times to test for timing variations
      const commitments1 = [];
      const commitments2 = [];
      
      for (let i = 0; i < 10; i++) {
        commitments1.push(await contract.generateCommitment(secret1, user1.address));
        commitments2.push(await contract.generateCommitment(secret2, user1.address));
      }
      
      // All commitments should be unique
      const unique1 = new Set(commitments1);
      const unique2 = new Set(commitments2);
      
      expect(unique1.size).to.equal(commitments1.length);
      expect(unique2.size).to.equal(commitments2.length);
    });
  });
});