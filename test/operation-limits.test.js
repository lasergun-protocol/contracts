const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("Operation Limits Tests", function () {
  let contract;
  let mockUSDC;
  let owner, user1, user2;
  
  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();
    
    // Deploy mock USDC
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6, 0, false);
    await mockUSDC.waitForDeployment();
    
    // Mint tokens to users
    await mockUSDC.mint(user1.address, ethers.parseUnits("10000000000", 6)); // 10B tokens
    await mockUSDC.mint(user2.address, ethers.parseUnits("10000", 6));
    
    // Deploy LaserGun with libraries
    contract = await deployLaserGunWithLibraries(
      owner.address, // admin
      10, // 0.1% shield fee (10 basis points)
      10, // 0.1% unshield fee (10 basis points)
      10  // 0.1% transfer fee (10 basis points)
    );
  });

  describe("Maximum Amount Limits", function () {
    it("Should reject shield operations exceeding maximum amount", async function () {
      // MAX_OPERATION_AMOUNT = 1_000_000 * 1e18 = 1e24
      // We need to exceed this amount
      const amount = ethers.parseUnits("2000000000000000000", 6); // 2e21 tokens (exceeds 1e24 limit when converted)
      const secret = ethers.randomBytes(32);
      const commitment = await contract.generateCommitment(secret, user1.address);
      const bloomFilter = ethers.randomBytes(32);
      
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      
      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
      ).to.be.revertedWithCustomError(contract, "AmountTooLarge");
    });

    it("Should accept shield operations within maximum amount", async function () {
      const amount = ethers.parseUnits("100000", 6); // 100K tokens (well within limit)
      const secret = ethers.randomBytes(32);
      const commitment = await contract.generateCommitment(secret, user1.address);
      const bloomFilter = ethers.randomBytes(32);
      
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      
      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
      ).to.not.be.reverted;
    });
  });

  describe("Operation Cooldown", function () {
    it("Should reject rapid consecutive operations", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret1 = ethers.randomBytes(32);
      const secret2 = ethers.randomBytes(32);
      const commitment1 = await contract.generateCommitment(secret1, user1.address);
      const commitment2 = await contract.generateCommitment(secret2, user1.address);
      const bloomFilter1 = ethers.randomBytes(32);
      const bloomFilter2 = ethers.randomBytes(32);
      
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount * 2n);
      
      // First operation should succeed
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment1, bloomFilter1);
      
      // Try second operation immediately with same user (should fail due to cooldown)
      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment2, bloomFilter2)
      ).to.be.revertedWithCustomError(contract, "OperationTooFrequent");
    });

    it("Should accept operations after cooldown period", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret1 = ethers.randomBytes(32);
      const secret2 = ethers.randomBytes(32);
      const commitment1 = await contract.generateCommitment(secret1, user1.address);
      const commitment2 = await contract.generateCommitment(secret2, user1.address);
      const bloomFilter1 = ethers.randomBytes(32);
      const bloomFilter2 = ethers.randomBytes(32);
      
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount * 2n);
      
      // First operation should succeed
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment1, bloomFilter1);
      
      // Wait for cooldown (2 seconds to be safe)
      await new Promise(resolve => setTimeout(resolve, 2100));
      
      // Second operation after cooldown should succeed
      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment2, bloomFilter2)
      ).to.not.be.reverted;
    });
  });

  describe("Maximum Shields Per User", function () {
    it("Should track shield count correctly", async function () {
      const amount = ethers.parseUnits("10", 6);
      
      // Create a few shields to verify counting works
      for (let i = 0; i < 3; i++) {
        const secret = ethers.randomBytes(32);
        const commitment = await contract.generateCommitment(secret, user1.address);
        const bloomFilter = ethers.randomBytes(32);
        
        await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
        
        // Wait for cooldown between operations
        if (i > 0) {
          await new Promise(resolve => setTimeout(resolve, 1100));
        }
        
        await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);
      }
      
      // Verify that shield count is tracked
      const shieldCount = await contract.userShieldCount(user1.address);
      expect(shieldCount).to.equal(3);
    });
  });
});