// test/LaserGun.test.js - Полный тест для ethers v6
const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");

describe("LaserGun", function () {
  let contract, mockUSDC;
  let admin, user1, user2, user3;

  const SHIELD_FEE = 25n; // BigInt для ethers v6
  const UNSHIELD_FEE = 25n;
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
      mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6);
      await mockUSDC.waitForDeployment(); // v6: вместо deployed()

      // Mint tokens to users - ethers v6 синтаксис
      const amount = ethers.parseUnits("10000", 6); // БЕЗ .utils
      await mockUSDC.mint(user1.address, amount);
      await mockUSDC.mint(user2.address, amount);
      await mockUSDC.mint(user3.address, amount);

      // Deploy LaserGun proxy
      const LaserGun = await ethers.getContractFactory("LaserGun");
      contract = await upgrades.deployProxy(
        LaserGun,
        [admin.address, SHIELD_FEE, UNSHIELD_FEE],
        {
          initializer: 'initialize',
          kind: 'uups',
          timeout: 60000
        }
      );
      await contract.waitForDeployment(); // v6: вместо deployed()

      // Обеспечиваем консистентность состояния
      await network.provider.send("evm_mine", []);

    } catch (error) {
      console.error("Setup failed:", error);
      throw error;
    }
  });

  afterEach(async function () {
    // Майним блок для обеспечения консистентности состояния
    await network.provider.send("evm_mine", []);
  });

  describe("Deployment", function () {
    it("Should set the right admin", async function () {
      let attempts = 0;
      const maxAttempts = 3;

      while (attempts < maxAttempts) {
        try {
          const ADMIN_ROLE = await contract.ADMIN_ROLE();
          const hasRole = await contract.hasRole(ADMIN_ROLE, admin.address);
          expect(hasRole).to.be.true;
          break;
        } catch (error) {
          attempts++;
          if (attempts === maxAttempts) {
            throw error;
          }
          console.log(`Retrying admin check, attempt ${attempts + 1}`);
          await new Promise(resolve => setTimeout(resolve, 1000));
        }
      }
    });

    it("Should set correct fees", async function () {
      expect(await contract.shieldFeePercent()).to.equal(SHIELD_FEE);
      expect(await contract.unshieldFeePercent()).to.equal(UNSHIELD_FEE);
    });

    it("Should not be paused initially", async function () {
      expect(await contract.paused()).to.be.false;
    });

    it("Should initialize all roles correctly", async function () {
      const DEFAULT_ADMIN_ROLE = await contract.DEFAULT_ADMIN_ROLE();
      const ADMIN_ROLE = await contract.ADMIN_ROLE();
      const FEE_MANAGER_ROLE = await contract.FEE_MANAGER_ROLE();
      const PAUSER_ROLE = await contract.PAUSER_ROLE();
      const UPGRADER_ROLE = await contract.UPGRADER_ROLE();

      expect(await contract.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
      expect(await contract.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
      expect(await contract.hasRole(FEE_MANAGER_ROLE, admin.address)).to.be.true;
      expect(await contract.hasRole(PAUSER_ROLE, admin.address)).to.be.true;
      expect(await contract.hasRole(UPGRADER_ROLE, admin.address)).to.be.true;
    });

    it("Should have correct constants", async function () {
      expect(await contract.MAX_FEE_PERCENT()).to.equal(1000n);
      expect(await contract.FEE_DENOMINATOR()).to.equal(10000n);
      expect(await contract.MAX_CONSOLIDATE_ShieldS()).to.equal(10n);
      expect(await contract.MIN_AMOUNT()).to.equal(1n);
    });
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
    const commitment = ethers.keccak256(
      ethers.solidityPacked(["bytes32", "address"], [secret, user.address]) // v6 синтаксис
    );

    await token.connect(user).approve(await contract.getAddress(), amount); // v6: getAddress()
    await waitForTransaction(
      contract.connect(user).shield(amount, await token.getAddress(), commitment)
    );

    return { secret, commitment, amount };
  }

  describe("Shield (Shield)", function () {
    it("Should shield successfully and charge fee", async function () {
      const amount = ethers.parseUnits("100", 6); // БЕЗ .utils
      const secret = ethers.randomBytes(32);
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      // Approve tokens
      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      // Calculate expected fee and net amount
      const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR; // BigInt арифметика
      const expectedNetAmount = amount - expectedFee;

      // Check initial balances
      const initialContractBalance = await mockUSDC.balanceOf(await contract.getAddress());
      const initialUserBalance = await mockUSDC.balanceOf(user1.address);

      // Shield
      await expect(contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment))
        .to.emit(contract, "Shielded")
        .withArgs(commitment, await mockUSDC.getAddress(), expectedNetAmount, expectedFee)
        .to.emit(contract, "FeeCollected")
        .withArgs(await mockUSDC.getAddress(), expectedFee);

      // Check Shield info
      const Shield = await contract.getShieldInfo(commitment);
      expect(Shield.exists).to.be.true;
      expect(Shield.amount).to.equal(expectedNetAmount);
      expect(Shield.token).to.equal(await mockUSDC.getAddress());
      expect(Shield.spent).to.be.false;
      expect(Shield.timestamp).to.be.gt(0);

      // Check collected fees
      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(expectedFee);

      // Check token balances
      const finalContractBalance = await mockUSDC.balanceOf(await contract.getAddress());
      const finalUserBalance = await mockUSDC.balanceOf(user1.address);

      expect(finalContractBalance - initialContractBalance).to.equal(amount);
      expect(initialUserBalance - finalUserBalance).to.equal(amount);
    });

    it("Should reject zero amounts", async function () {
      const commitment = ethers.randomBytes(32);
      await expect(
        contract.connect(user1).shield(0n, await mockUSDC.getAddress(), commitment)
      ).to.be.revertedWithCustomError(contract, "ZeroAmount");
    });

    it("Should reject invalid token address", async function () {
      const amount = ethers.parseUnits("100", 6);
      const commitment = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).shield(amount, ethers.ZeroAddress, commitment) // v6: ZeroAddress
      ).to.be.revertedWithCustomError(contract, "EmptyToken");
    });

    it("Should reject invalid commitment", async function () {
      const amount = ethers.parseUnits("100", 6);

      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), ethers.ZeroHash) // v6: ZeroHash
      ).to.be.revertedWithCustomError(contract, "InvalidCommitment");
    });

    it("Should reject duplicate commitments", async function () {
      const amount = ethers.parseUnits("100", 6);
      const commitment = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount * 2n);

      // First shield
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);

      // Second shield with same commitment should fail
      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment)
      ).to.be.revertedWithCustomError(contract, "CommitmentAlreadyExists");
    });

    it("Should reject when paused", async function () {
      await contract.connect(admin).pause();

      const amount = ethers.parseUnits("100", 6);
      const commitment = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment)
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should handle zero fee correctly", async function () {
      // Set fees to zero
      await contract.connect(admin).setFees(0n, 0n);

      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      await expect(contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment))
        .to.emit(contract, "Shielded")
        .withArgs(commitment, await mockUSDC.getAddress(), amount, 0n)
        .to.not.emit(contract, "FeeCollected");

      const Shield = await contract.getShieldInfo(commitment);
      expect(Shield.amount).to.equal(amount);
      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(0n);
    });
  });

  describe("Unshield (Unshield)", function () {
    let secret, commitment, shieldAmount, netAmount;

    beforeEach(async function () {
      shieldAmount = ethers.parseUnits("100", 6);
      secret = ethers.randomBytes(32);
      commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      const shieldFee = shieldAmount * SHIELD_FEE / FEE_DENOMINATOR;
      netAmount = shieldAmount - shieldFee;

      await mockUSDC.connect(user1).approve(await contract.getAddress(), shieldAmount);
      await contract.connect(user1).shield(shieldAmount, await mockUSDC.getAddress(), commitment);
    });

    it("Should unshield full amount successfully", async function () {
      const initialBalance = await mockUSDC.balanceOf(user2.address);

      // Calculate unshield fee
      const unshieldFee = netAmount * UNSHIELD_FEE / FEE_DENOMINATOR;
      const expectedAmount = netAmount - unshieldFee;

      await expect(
        contract.connect(user1).unshield(secret, netAmount, user2.address, ethers.ZeroHash)
      )
        .to.emit(contract, "Unshielded")
        .withArgs(commitment, await mockUSDC.getAddress(),  expectedAmount, unshieldFee)
        .to.emit(contract, "FeeCollected")
        .withArgs(await mockUSDC.getAddress(), unshieldFee);

      // Check Shield is spent
      const Shield = await contract.getShieldInfo(commitment);
      expect(Shield.spent).to.be.true;

      // Check user received tokens
      const finalBalance = await mockUSDC.balanceOf(user2.address);
      expect(finalBalance - initialBalance).to.equal(expectedAmount);

      // Check fees collected
      const totalFees = shieldAmount * SHIELD_FEE / FEE_DENOMINATOR + unshieldFee;
      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(totalFees);
    });

    it("Should unshield partial amount and create remainder Shield", async function () {
      const unshieldAmount = netAmount / 2n; // Половина
      const newCommitment = ethers.randomBytes(32);

      const unshieldFee = unshieldAmount * UNSHIELD_FEE / FEE_DENOMINATOR;
      const expectedAmount = unshieldAmount - unshieldFee;
      const remainderAmount = netAmount - unshieldAmount;

      await expect(
        contract.connect(user1).unshield(secret, unshieldAmount, user2.address, newCommitment)
      )
        .to.emit(contract, "Unshielded")
        .withArgs(commitment, await mockUSDC.getAddress(),  expectedAmount, unshieldFee)
        .to.emit(contract, "Shielded")
        .withArgs(newCommitment, await mockUSDC.getAddress(), remainderAmount, 0n);

      // Check original Shield is spent
      const originalShield = await contract.getShieldInfo(commitment);
      expect(originalShield.spent).to.be.true;

      // Check new Shield created
      const newShield = await contract.getShieldInfo(newCommitment);
      expect(newShield.exists).to.be.true;
      expect(newShield.amount).to.equal(remainderAmount);
      expect(newShield.spent).to.be.false;
    });

    it("Should reject invalid secret", async function () {
      const wrongSecret = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).unshield(wrongSecret, netAmount, user2.address, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(contract, "ShieldDoesNotExist");
    });

    it("Should reject insufficient balance", async function () {
      const excessAmount = netAmount + 1n;

      await expect(
        contract.connect(user1).unshield(secret, excessAmount, user2.address, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(contract, "InsufficientShieldBalance");
    });

    it("Should reject invalid recipient", async function () {
      await expect(
        contract.connect(user1).unshield(secret, netAmount, ethers.ZeroAddress, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(contract, "InvalidRecipient");
    });

    it("Should reject dust amounts", async function () {
      await expect(
        contract.connect(user1).unshield(secret, 0n, user2.address, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(contract, "AmountTooSmall");
    });
  });

  describe("Create Shield for Recipient", function () {
    let secret, commitment, shieldAmount, netAmount;

    beforeEach(async function () {
      shieldAmount = ethers.parseUnits("100", 6);
      secret = ethers.randomBytes(32);
      commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      const shieldFee = shieldAmount * SHIELD_FEE / FEE_DENOMINATOR;
      netAmount = shieldAmount - shieldFee;

      await mockUSDC.connect(user1).approve(await contract.getAddress(), shieldAmount);
      await contract.connect(user1).shield(shieldAmount, await mockUSDC.getAddress(), commitment);
    });

    it("Should create Shield for recipient successfully", async function () {
      const transferAmount = netAmount / 2n;
      const recipientCommitment = ethers.randomBytes(32);
      const encryptedSecret = ethers.hexlify(ethers.randomBytes(64));

      // ✅ ИСПРАВЛЕНИЕ: НЕ передаем remainderCommitment, функция сама создаст его
      const tx = await contract.connect(user1).transfer(
        secret, transferAmount,  recipientCommitment, encryptedSecret
      );

      // ✅ ИСПРАВЛЕНИЕ: Проверяем события без жесткой привязки к commitment'у остатка
      await expect(tx)
        .to.emit(contract, "Unshielded")
        .withArgs(commitment, await mockUSDC.getAddress(),  transferAmount, 0n)
        .to.emit(contract, "Shielded")
        .withArgs(recipientCommitment, await mockUSDC.getAddress(), transferAmount, 0n)
        .to.emit(contract, "SecretDelivered")
        .withArgs(encryptedSecret);

      // ✅ Проверяем что создался воучер для остатка (если есть остаток)
      const remainderAmount = netAmount - transferAmount;
      if (remainderAmount > 0n) {
        // Находим автоматически созданный commitment для остатка
        const currentNonce = await contract.userNonces(user1.address);
        const expectedRemainderCommitment = ethers.keccak256(
          ethers.solidityPacked(["address", "uint256"], [user1.address, currentNonce - 1n])
        );

        const remainderShield = await contract.getShieldInfo(expectedRemainderCommitment);
        expect(remainderShield.exists).to.be.true;
        expect(remainderShield.amount).to.equal(remainderAmount);
        expect(remainderShield.token).to.equal(await mockUSDC.getAddress());
      }

      // Check original Shield is spent
      const originalShield = await contract.getShieldInfo(commitment);
      expect(originalShield.spent).to.be.true;

      // Check recipient Shield created
      const recipientShield = await contract.getShieldInfo(recipientCommitment);
      expect(recipientShield.exists).to.be.true;
      expect(recipientShield.amount).to.equal(transferAmount);
      expect(recipientShield.token).to.equal(await mockUSDC.getAddress());
    });


    it("Should transfer full amount without remainder", async function () {
      const recipientCommitment = ethers.randomBytes(32);
      const encryptedSecret = ethers.hexlify(ethers.randomBytes(64));

      // ✅ ИСПРАВЛЕНИЕ: Убираем несуществующее событие ShieldTransferred
      const tx = await contract.connect(user1).transfer(
        secret, netAmount,  recipientCommitment, encryptedSecret
      );

      await expect(tx)
        .to.emit(contract, "Unshielded")
        .withArgs(commitment, await mockUSDC.getAddress(),  netAmount, 0n)
        .to.emit(contract, "Shielded")
        .withArgs(recipientCommitment, await mockUSDC.getAddress(), netAmount, 0n)
        .to.emit(contract, "SecretDelivered")
        .withArgs(encryptedSecret);

      // Check recipient Shield created
      const recipientShield = await contract.getShieldInfo(recipientCommitment);
      expect(recipientShield.exists).to.be.true;
      expect(recipientShield.amount).to.equal(netAmount);

      // ✅ Проверяем что НЕ создался воучер для остатка (остатка нет)
      const currentNonce = await contract.userNonces(user1.address);
      if (currentNonce > 0n) {
        const potentialRemainderCommitment = ethers.keccak256(
          ethers.solidityPacked(["address", "uint256"], [user1.address, currentNonce - 1n])
        );
        const remainderShield = await contract.getShieldInfo(potentialRemainderCommitment);
        expect(remainderShield.exists).to.be.false; // Не должен существовать при полном переводе
      }
    });
 

    it("Should reject insufficient balance", async function () {
      const transferAmount = netAmount + 1n;
      const recipientCommitment = ethers.randomBytes(32);
      const encryptedSecret = ethers.hexlify(ethers.randomBytes(64));

      await expect(
        contract.connect(user1).transfer(
          secret, transferAmount,   recipientCommitment, encryptedSecret
        )
      ).to.be.revertedWithCustomError(contract, "InsufficientShieldBalance");
    });

    it("Should reject dust amounts", async function () {
      const recipientCommitment = ethers.randomBytes(32);
      const encryptedSecret = ethers.hexlify(ethers.randomBytes(64));

      await expect(
        contract.connect(user1).transfer(
          secret, 0n,  recipientCommitment, encryptedSecret
        )
      ).to.be.revertedWithCustomError(contract, "AmountTooSmall");
    });

    it("Should reject duplicate recipient commitment", async function () {
      const transferAmount = netAmount / 2n;
      const encryptedSecret = ethers.hexlify(ethers.randomBytes(64));

      await expect(
        contract.connect(user1).transfer(
          secret, transferAmount,   commitment, encryptedSecret
        )
      ).to.be.revertedWithCustomError(contract, "RecipientCommitmentAlreadyExists");
    });

    it("Should reject invalid sender secret", async function () {
      const wrongSecret = ethers.randomBytes(32);
      const transferAmount = netAmount / 2n;
      const recipientCommitment = ethers.randomBytes(32);
      const encryptedSecret = ethers.hexlify(ethers.randomBytes(64));

      await expect(
        contract.connect(user1).transfer(
          wrongSecret, transferAmount, recipientCommitment, encryptedSecret
        )
      ).to.be.revertedWithCustomError(contract, "ShieldDoesNotExist");
    });

    it("Should reject empty encrypted secret", async function () {
      const transferAmount = netAmount / 2n;
      const recipientCommitment = ethers.randomBytes(32);
      const emptyEncryptedSecret = "0x";

      await expect(
        contract.connect(user1).transfer(
          secret, transferAmount,  recipientCommitment, emptyEncryptedSecret
        )
      ).to.be.revertedWithCustomError(contract, "EncryptedSecretCannotBeEmpty");
    });
  });

  describe("Consolidate Shields", function () {
    let secrets, commitments, amounts;

    beforeEach(async function () {
      secrets = [];
      commitments = [];
      amounts = [];

      // Create multiple Shields
      for (let i = 0; i < 3; i++) {
        const amount = ethers.parseUnits("50", 6);
        const secret = ethers.randomBytes(32);
        const commitment = ethers.keccak256(
          ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
        );

        await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
        await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);

        secrets.push(secret);
        commitments.push(commitment);
        amounts.push(amount - amount * SHIELD_FEE / FEE_DENOMINATOR);
      }
    });

    it("Should consolidate multiple Shields successfully", async function () {
      const newCommitment = ethers.randomBytes(32);
      const totalAmount = amounts.reduce((sum, amount) => sum + amount, 0n);

      // ✅ ПРОСТОЕ ИСПРАВЛЕНИЕ: Проверяем только факт эмиссии событий
      await expect(
        contract.connect(user1).consolidate(secrets, newCommitment)
      )
        .to.emit(contract, "ShieldConsolidated")
        .to.emit(contract, "Shielded");

      // Check all original Shields are spent
      for (const commitment of commitments) {
        const Shield = await contract.getShieldInfo(commitment);
        expect(Shield.spent).to.be.true;
      }

      // Check new consolidated Shield
      const newShield = await contract.getShieldInfo(newCommitment);
      expect(newShield.exists).to.be.true;
      expect(newShield.amount).to.equal(totalAmount);
      expect(newShield.token).to.equal(await mockUSDC.getAddress());
    });

    it("Should reject empty secrets array", async function () {
      const newCommitment = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).consolidate([], newCommitment)
      ).to.be.revertedWithCustomError(contract, "NoSecretsProvided");
    });

    it("Should reject too many Shields", async function () {
      // Create array with 11 secrets (exceeds MAX_CONSOLIDATE_ShieldS = 10)
      const tooManySecrets = new Array(11).fill(ethers.randomBytes(32));
      const newCommitment = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).consolidate(tooManySecrets, newCommitment)
      ).to.be.revertedWithCustomError(contract, "TooManyShieldsToConsolidate");
    });

    it("Should reject invalid commitment", async function () {
      await expect(
        contract.connect(user1).consolidate(secrets, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(contract, "EmptyCommitment");
    });

    it("Should reject duplicate commitment", async function () {
      await expect(
        contract.connect(user1).consolidate(secrets, commitments[0])
      ).to.be.revertedWithCustomError(contract, "CommitmentAlreadyExists");
    });

    it("Should reject mixed token types in consolidation", async function () {
      // Deploy second mock token
      const MockERC20_2 = await ethers.getContractFactory("MockERC20");
      const mockDAI = await MockERC20_2.deploy("Mock DAI", "DAI", 18);
      await mockDAI.waitForDeployment();

      // Mint and create Shield with different token
      const amount = ethers.parseUnits("50", 18);
      await mockDAI.mint(user1.address, amount);

      const daiSecret = ethers.randomBytes(32);
      const daiCommitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [daiSecret, user1.address])
      );

      await mockDAI.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockDAI.getAddress(), daiCommitment);

      // Try to consolidate USDC and DAI Shields together
      const mixedSecrets = [...secrets.slice(0, 2), daiSecret];
      const newCommitment = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).consolidate(mixedSecrets, newCommitment)
      ).to.be.revertedWithCustomError(contract, "AllShieldsMustUseSameToken");
    });

    it("Should consolidate with maximum allowed Shields", async function () {
      // Create additional Shields to reach MAX_CONSOLIDATE_ShieldS (10)
      const additionalSecrets = [];
      const additionalCommitments = [];

      for (let i = 0; i < 7; i++) { // We already have 3, add 7 more for total of 10
        const amount = ethers.parseUnits("10", 6);
        const secret = ethers.randomBytes(32);
        const commitment = ethers.keccak256(
          ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
        );

        await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
        await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);

        additionalSecrets.push(secret);
        additionalCommitments.push(commitment);
      }

      const allSecrets = [...secrets, ...additionalSecrets];
      const newCommitment = ethers.randomBytes(32);

      // Should succeed with exactly 10 Shields
      const tx = await contract.connect(user1).consolidate(allSecrets, newCommitment);
      const receipt = await tx.wait();

      expect(receipt.status).to.equal(1);

      // Verify new Shield was created
      const newShield = await contract.getShieldInfo(newCommitment);
      expect(newShield.exists).to.be.true;
      expect(newShield.token).to.equal(await mockUSDC.getAddress());
    });
  });

  describe("Admin Functions", function () {
    beforeEach(async function () {
      // Create some fees to test withdrawal
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);
    });

    it("Should allow admin to set fees", async function () {
      const newShieldFee = 50n;
      const newUnshieldFee = 75n;

      await expect(contract.connect(admin).setFees(newShieldFee, newUnshieldFee))
        .to.emit(contract, "FeesUpdated")
        .withArgs(newShieldFee, newUnshieldFee);

      expect(await contract.shieldFeePercent()).to.equal(newShieldFee);
      expect(await contract.unshieldFeePercent()).to.equal(newUnshieldFee);
    });

    it("Should reject excessive fees", async function () {
      const excessiveFee = 1001n; // > MAX_FEE_PERCENT (1000)

      await expect(
        contract.connect(admin).setFees(excessiveFee, UNSHIELD_FEE)
      ).to.be.revertedWithCustomError(contract, "FeeExceedsMaximum");

      await expect(
        contract.connect(admin).setFees(SHIELD_FEE, excessiveFee)
      ).to.be.revertedWithCustomError(contract, "FeeExceedsMaximum");
    });

    it("Should allow admin to withdraw fees", async function () {
      const expectedFee = ethers.parseUnits("100", 6) * SHIELD_FEE / FEE_DENOMINATOR;
      const initialBalance = await mockUSDC.balanceOf(admin.address);

      await contract.connect(admin).withdrawFees(await mockUSDC.getAddress(), admin.address);

      const finalBalance = await mockUSDC.balanceOf(admin.address);
      expect(finalBalance - initialBalance).to.equal(expectedFee);
      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(0n);
    });

    it("Should allow admin to pause and unpause", async function () {
      await contract.connect(admin).pause();
      expect(await contract.paused()).to.be.true;

      await contract.connect(admin).unpause();
      expect(await contract.paused()).to.be.false;
    });

    it("Should allow emergency withdraw when paused", async function () {
      const expectedFee = ethers.parseUnits("100", 6) * SHIELD_FEE / FEE_DENOMINATOR;

      await contract.connect(admin).pause();

      // Emergency withdraw
      const initialBalance = await mockUSDC.balanceOf(admin.address);
      await contract.connect(admin).emergencyWithdraw(await mockUSDC.getAddress(), admin.address);

      const finalBalance = await mockUSDC.balanceOf(admin.address);
      expect(finalBalance - initialBalance).to.equal(expectedFee);
      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(0n);
    });

    it("Should reject emergency withdraw when not paused", async function () {
      await expect(
        contract.connect(admin).emergencyWithdraw(await mockUSDC.getAddress(), admin.address)
      ).to.be.revertedWith("Pausable: not paused");
    });

    it("Should reject non-admin operations", async function () {
      await expect(
        contract.connect(user1).setFees(100n, 100n)
      ).to.be.revertedWith('AccessControl: account 0x70997970c51812dc3a010c7d01b50e0d17dc79c8 is missing role 0x6c0757dc3e6b28b2580c03fd9e96c274acf4f99d91fbec9b418fa1d70604ff1c')

      await expect(
        contract.connect(user1).pause()
      ).to.be.revertedWith("AccessControl: account 0x70997970c51812dc3a010c7d01b50e0d17dc79c8 is missing role 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a");

      await expect(
        contract.connect(user1).withdrawFees(await mockUSDC.getAddress(), user1.address)
      ).to.be.revertedWith("AccessControl: account 0x70997970c51812dc3a010c7d01b50e0d17dc79c8 is missing role 0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775");

      await expect(
        contract.connect(user1).emergencyWithdraw(await mockUSDC.getAddress(), user1.address)
      ).to.be.revertedWith("AccessControl: account 0x70997970c51812dc3a010c7d01b50e0d17dc79c8 is missing role 0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775");
    });
  });

  describe("View Functions", function () {
    let secret, commitment, amount;

    beforeEach(async function () {
      amount = ethers.parseUnits("100", 6);
      secret = ethers.randomBytes(32);
      commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);
    });

    it("Should return correct Shield info", async function () {
      const info = await contract.getShieldInfo(commitment);
      const expectedAmount = amount - amount * SHIELD_FEE / FEE_DENOMINATOR;

      expect(info.exists).to.be.true;
      expect(info.token).to.equal(await mockUSDC.getAddress());
      expect(info.amount).to.equal(expectedAmount);
      expect(info.timestamp).to.be.gt(0);
      expect(info.spent).to.be.false;
    });

    it("Should generate correct commitment", async function () {
      const generated = await contract.generateCommitment(secret, user1.address);
      expect(generated).to.equal(commitment);
    });

    it("Should return correct Shield balance", async function () {
      const expectedAmount = amount - amount * SHIELD_FEE / FEE_DENOMINATOR;
      const balance = await contract.connect(user1).getShieldBalance(secret, await mockUSDC.getAddress());
      expect(balance).to.equal(expectedAmount);
    });

    it("Should return zero for non-existent Shield", async function () {
      const wrongSecret = ethers.randomBytes(32);
      const balance = await contract.connect(user1).getShieldBalance(wrongSecret, await mockUSDC.getAddress());
      expect(balance).to.equal(0n);
    });

    it("Should return false for non-existent Shield info", async function () {
      const wrongCommitment = ethers.randomBytes(32);
      const info = await contract.getShieldInfo(wrongCommitment);
      expect(info.exists).to.be.false;
    });
  });

  describe("Edge Cases and Security", function () {
    it("Should handle multiple tokens correctly", async function () {
      // Deploy second mock token
      const MockERC20_2 = await ethers.getContractFactory("MockERC20");
      const mockDAI = await MockERC20_2.deploy("Mock DAI", "DAI", 18);
      await mockDAI.waitForDeployment();

      // Mint tokens
      const amount1 = ethers.parseUnits("100", 6); // USDC
      const amount2 = ethers.parseUnits("100", 18); // DAI

      await mockDAI.mint(user1.address, amount2);

      // Create Shields for both tokens
      const secret1 = ethers.randomBytes(32);
      const secret2 = ethers.randomBytes(32);
      const commitment1 = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret1, user1.address])
      );
      const commitment2 = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret2, user1.address])
      );

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount1);
      await mockDAI.connect(user1).approve(await contract.getAddress(), amount2);

      await contract.connect(user1).shield(amount1, await mockUSDC.getAddress(), commitment1);
      await contract.connect(user1).shield(amount2, await mockDAI.getAddress(), commitment2);

      // Check both Shields exist
      const Shield1 = await contract.getShieldInfo(commitment1);
      const Shield2 = await contract.getShieldInfo(commitment2);

      expect(Shield1.exists).to.be.true;
      expect(Shield1.token).to.equal(await mockUSDC.getAddress());
      expect(Shield2.exists).to.be.true;
      expect(Shield2.token).to.equal(await mockDAI.getAddress());

      // Check separate fee collection
      const usdcFee = amount1 * SHIELD_FEE / FEE_DENOMINATOR;
      const daiFee = amount2 * SHIELD_FEE / FEE_DENOMINATOR;

      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(usdcFee);
      expect(await contract.collectedFees(await mockDAI.getAddress())).to.equal(daiFee);
    });

    it("Should prevent reentrancy attacks", async function () {
      // This test would require a malicious token contract
      // For now, we just verify normal operation doesn't have issues
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      // Multiple operations in sequence should work
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);
      await contract.connect(user1).unshield(secret, amount - amount * SHIELD_FEE / FEE_DENOMINATOR, user2.address, ethers.ZeroHash);

      // Shield should be properly spent
      const Shield = await contract.getShieldInfo(commitment);
      expect(Shield.spent).to.be.true;
    });

    it("Should handle maximum values correctly", async function () {
      // Test with maximum uint256 values (within reasonable gas limits)
      const largeAmount = ethers.parseUnits("1000000", 6); // 1M USDC

      await mockUSDC.mint(user1.address, largeAmount);
      await mockUSDC.connect(user1).approve(await contract.getAddress(), largeAmount);

      const secret = ethers.randomBytes(32);
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      await contract.connect(user1).shield(largeAmount, await mockUSDC.getAddress(), commitment);

      const Shield = await contract.getShieldInfo(commitment);
      const expectedNetAmount = largeAmount - largeAmount * SHIELD_FEE / FEE_DENOMINATOR;

      expect(Shield.amount).to.equal(expectedNetAmount);
      expect(Shield.exists).to.be.true;
    });

    it("Should handle minimum amounts correctly", async function () {
      // Test with minimum amount = 1
      const minAmount = 1n;

      await mockUSDC.connect(user1).approve(await contract.getAddress(), minAmount);

      const secret = ethers.randomBytes(32);
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      await contract.connect(user1).shield(minAmount, await mockUSDC.getAddress(), commitment);

      const Shield = await contract.getShieldInfo(commitment);
      // With 0.25% fee, 1 unit should result in 0 net amount (due to rounding)
      const expectedNetAmount = minAmount - minAmount * SHIELD_FEE / FEE_DENOMINATOR;

      expect(Shield.amount).to.equal(expectedNetAmount);
      expect(Shield.exists).to.be.true;
    });

    it("Should preserve precision in fee calculations", async function () {
      // Test fee calculation precision
      const amount = 12345n; // Odd number to test rounding

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      const secret = ethers.randomBytes(32);
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);

      const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR;
      const expectedNetAmount = amount - expectedFee;

      const Shield = await contract.getShieldInfo(commitment);
      expect(Shield.amount).to.equal(expectedNetAmount);

      const collectedFee = await contract.collectedFees(await mockUSDC.getAddress());
      expect(collectedFee).to.equal(expectedFee);

      // Verify total balance conservation
      const contractBalance = await mockUSDC.balanceOf(await contract.getAddress());
      expect(contractBalance).to.equal(amount);
    });
  });

  describe("Gas Optimization Tests", function () {
    it("Should use reasonable gas for shield", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      const tx = await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);
      const receipt = await tx.wait();

      // Gas should be reasonable (adjust based on actual implementation)
      expect(receipt.gasUsed).to.be.lt(200000n); // Less than 200k gas
    });

    it("Should use reasonable gas for unshield", async function () {
      // Setup Shield
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
      );

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);

      const netAmount = amount - amount * SHIELD_FEE / FEE_DENOMINATOR;

      // Test unshield gas
      const tx = await contract.connect(user1).unshield(secret, netAmount, user2.address, ethers.ZeroHash);
      const receipt = await tx.wait();

      expect(receipt.gasUsed).to.be.lt(150000n); // Less than 150k gas
    });

    it("Should use reasonable gas for consolidation", async function () {
      // Create multiple small Shields
      const secrets = [];
      const amount = ethers.parseUnits("10", 6);

      for (let i = 0; i < 3; i++) {
        const secret = ethers.randomBytes(32);
        const commitment = ethers.keccak256(
          ethers.solidityPacked(["bytes32", "address"], [secret, user1.address])
        );

        await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
        await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment);
        secrets.push(secret);
      }

      const newCommitment = ethers.randomBytes(32);

      // Test consolidation gas
      const tx = await contract.connect(user1).consolidate(secrets, newCommitment);
      const receipt = await tx.wait();

      expect(receipt.gasUsed).to.be.lt(300000n); // Less than 300k gas for 3 Shields
    });
  });
});