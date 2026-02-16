// test/LaserGun.test.fixed.js - Исправленный тест для ethers v6
const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun", function () {
  let contract, mockUSDC;
  let admin, user1, user2, user3;

  const SHIELD_FEE = 25n; // BigInt для ethers v6
  const UNSHIELD_FEE = 25n;
  const TRANSFER_FEE = 25n;
  const FEE_DENOMINATOR = 10000n;

  before(async function () {
    // Сброс состояния сети перед всеми тестами
    await network.provider.send("hardhat_reset", []);
  });

  beforeEach(async function () {
    try {
      [admin, user1, user2, user3] = await ethers.getSigners();

      // Deploy mock USDC token
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6, 0, false);
      await mockUSDC.waitForDeployment(); // v6: вместо deployed()

      // Mint tokens to users - ethers v6 синтаксис
      const amount = ethers.parseUnits("10000", 6); // БЕЗ .utils
      await mockUSDC.mint(user1.address, amount);
      await mockUSDC.mint(user2.address, amount);
      await mockUSDC.mint(user3.address, amount);

      // Deploy LaserGun proxy with libraries
      contract = await deployLaserGunWithLibraries(admin.address, SHIELD_FEE, UNSHIELD_FEE, TRANSFER_FEE);

      // Обеспечиваем консистентность состояния
      await network.provider.send("evm_mine", []);
    } catch (error) {
      console.error("BeforeEach setup failed:", error);
      throw error;
    }
  });

  // Helper functions для ethers v6
  async function waitForTransaction(txPromise) {
    const tx = await txPromise;
    const receipt = await tx.wait();
    await network.provider.send("evm_mine", []);
    return receipt;
  }

  async function createTestShield(user, amount, token = mockUSDC) {
    const secret = ethers.randomBytes(32); // БЕЗ .utils
    
    // Используем функцию контракта для генерации коммитмента
    const commitment = await contract.generateCommitment(secret, user.address);
    const bloomFilter = ethers.randomBytes(32); // БЕЗ .utils

    await token.connect(user).approve(await contract.getAddress(), amount);
    await waitForTransaction(
      contract.connect(user).shield(amount, await token.getAddress(), commitment, bloomFilter)
    );

    return { secret, commitment, amount, bloomFilter };
  }

  describe("Shield (Shield)", function () {
    it("Should shield successfully and charge fee", async function () {
      const amount = ethers.parseUnits("100", 6); // БЕЗ .utils
      const secret = ethers.randomBytes(32); // БЕЗ .utils
      const commitment = await contract.generateCommitment(secret, user1.address);
      const bloomFilter = ethers.randomBytes(32); // БЕЗ .utils

      // Approve tokens
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      // Calculate expected fee and net amount
      const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR; // BigInt арифметика
      const expectedNetAmount = amount - expectedFee;

      // Check initial balances
      const initialContractBalance = await mockUSDC.balanceOf(await contract.getAddress());
      const initialUserBalance = await mockUSDC.balanceOf(user1.address);

      // Shield
      await expect(contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter))
        .to.emit(contract, "Shielded")
        .withArgs(commitment, await mockUSDC.getAddress(), expectedNetAmount, expectedFee, bloomFilter)
        .to.emit(contract, "FeeCollected")
        .withArgs(await mockUSDC.getAddress(), expectedFee);

      // Check final balances
      const finalContractBalance = await mockUSDC.balanceOf(await contract.getAddress());
      const finalUserBalance = await mockUSDC.balanceOf(user1.address);

      // Verify balance changes
      expect(finalContractBalance).to.equal(initialContractBalance + amount);
      expect(finalUserBalance).to.equal(initialUserBalance - amount);

      // Check shield info
      const [exists, token, shieldAmount, timestamp, spent] = await contract.getShieldInfo(commitment);
      expect(exists).to.be.true;
      expect(token).to.equal(await mockUSDC.getAddress());
      expect(shieldAmount).to.equal(expectedNetAmount);
      expect(spent).to.be.false;
    });

    it("Should fail with invalid amount", async function () {
      const secret = ethers.randomBytes(32);
      const commitment = await contract.generateCommitment(secret, user1.address);
      const bloomFilter = ethers.randomBytes(32);

      await expect(contract.connect(user1).shield(0, await mockUSDC.getAddress(), commitment, bloomFilter))
        .to.be.revertedWithCustomError("ZeroAmount");
    });

    it("Should fail with existing commitment", async function () {
      const { commitment, bloomFilter } = await createTestShield(user1, ethers.parseUnits("100", 6));
      
      await expect(contract.connect(user1).shield(ethers.parseUnits("100", 6), await mockUSDC.getAddress(), commitment, bloomFilter))
        .to.be.revertedWithCustomError("CommitmentAlreadyExists");
    });
  });

  describe("View Functions", function () {
    it("Should generate commitment correctly", async function () {
      const secret = ethers.randomBytes(32);
      
      // Get initial nonce
      const initialNonce = await contract.userNonces(user1.address);
      
      // Generate commitment
      const commitment1 = await contract.generateCommitment(secret, user1.address);
      
      // Create a shield to increment nonce
      await createTestShield(user1, ethers.parseUnits("100", 6));
      
      // Generate commitment with incremented nonce
      const commitment2 = await contract.generateCommitment(secret, user1.address);
      
      // Commitments should be different due to nonce increment
      expect(commitment1).to.not.equal(commitment2);
      
      // Final nonce should be incremented
      const finalNonce = await contract.userNonces(user1.address);
      expect(finalNonce).to.equal(initialNonce + 1n);
    });

    it("Should get shield info correctly", async function () {
      const { commitment } = await createTestShield(user1, ethers.parseUnits("100", 6));
      
      const [exists, token, amount, timestamp, spent] = await contract.getShieldInfo(commitment);
      
      expect(exists).to.be.true;
      expect(token).to.equal(await mockUSDC.getAddress());
      expect(amount).to.be.gt(0);
      expect(timestamp).to.be.gt(0);
      expect(spent).to.be.false;
    });
  });

  describe("Transfer Function", function () {
    it("Should transfer tokens between users", async function () {
      const amount = ethers.parseUnits("100", 6);
      const { secret, commitment } = await createTestShield(user1, amount);
      
      // Generate recipient commitment
      const recipientSecret = ethers.randomBytes(32);
      const recipientCommitment = await contract.generateCommitment(recipientSecret, user2.address);
      const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
      const bloomFilter = ethers.randomBytes(32);

      // Transfer
      await expect(contract.connect(user1).transfer(
        secret,
        amount,
        recipientCommitment,
        encryptedSecret,
        bloomFilter
      ))
        .to.emit(contract, "SecretDelivered")
        .withArgs(encryptedSecret, bloomFilter);

      // Check recipient shield exists
      const [exists] = await contract.getShieldInfo(recipientCommitment);
      expect(exists).to.be.true;
    });
  });

  describe("Consolidate Function", function () {
    it("Should consolidate multiple shields", async function () {
      const amount = ethers.parseUnits("50", 6);
      const shields = [];
      
      // Create multiple shields
      for (let i = 0; i < 3; i++) {
        const { commitment, secret } = await createTestShield(user1, amount);
        shields.push({ commitment, secret });
      }
      
      // Generate new commitment for consolidated shield
      const newSecret = ethers.randomBytes(32);
      const newCommitment = await contract.generateCommitment(newSecret, user1.address);
      
      // Consolidate
      await expect(contract.connect(user1).consolidate(
        shields.map(s => s.secret),
        newCommitment
      ))
        .to.emit(contract, "ShieldConsolidated")
        .withArgs(shields.map(s => s.commitment), newCommitment);

      // Check consolidated shield exists
      const [exists] = await contract.getShieldInfo(newCommitment);
      expect(exists).to.be.true;
    });
  });
});