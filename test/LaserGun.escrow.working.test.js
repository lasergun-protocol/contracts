// test/LaserGun.escrow.working.test.js - Рабочая версия escrow-тестов с исправленной логикой коммитментов
const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun Escrow - Working Version", function () {
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

  // Создаем специальную функцию для генерации коммитмента с контролируемыми значениями блока
  async function generateControlledCommitment(secret, user, contractAddr, timestamp, prevrandao, nonce) {
    return ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user, timestamp, prevrandao, contractAddr, nonce]
      )
    );
  }

  async function createTestEscrowShield(user, amount, recipient, token = mockUSDC) {
    const secret = ethers.randomBytes(32);
    
    // Получаем текущие данные блока и сохраняем их
    const block = await ethers.provider.getBlock("latest");
    const timestamp = block.timestamp;
    const prevrandao = block.prevrandao || ethers.ZeroHash;
    const contractAddress = await contract.getAddress();
    
    // Получаем текущий nonce пользователя
    const nonce = await contract.userNonces(user.address);
    
    // Генерируем коммитмент с текущими значениями
    const commitment = await generateControlledCommitment(
      secret, 
      user.address, 
      contractAddress, 
      timestamp, 
      prevrandao, 
      nonce
    );
    
    const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
    const bloomFilter = ethers.randomBytes(32);
    const tokenAddress = typeof token === 'string' ? token : await token.getAddress();

    // Сначала создаем обычный shield
    await token.connect(user).approve(contractAddress, amount);
    await waitForTransaction(
      contract.connect(user).shield(amount, tokenAddress, commitment, bloomFilter)
    );
    
    // Затем помечаем его как escrow
    await waitForTransaction(
      contract.connect(user).createEscrowShield(
        commitment,
        encryptedSecret,
        bloomFilter
      )
    );

    // Возвращаем все данные, включая сохраненные значения блока
    return { 
      secret, 
      commitment, 
      amount, 
      bloomFilter, 
      recipient, 
      encryptedSecret,
      timestamp,
      prevrandao,
      nonce
    };
  }

  describe("Create Escrow Shield", function () {
    it("Should create escrow shield successfully", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      // Calculate expected fee and net amount
      const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR;
      const expectedNetAmount = amount - expectedFee;

      // Check escrow info
      const [escrowData, shield] = await contract.getEscrowInfo(escrow.commitment);
      expect(escrowData.commitment).to.equal(escrow.commitment);
      
      // Check shield info
      expect(Number(shield.flags & 1n)).to.equal(1); // exists flag
      expect(Number((shield.flags >> 2n) & 1n)).to.equal(1); // isEscrow flag
      expect(shield.amount).to.equal(expectedNetAmount);
      expect(shield.token).to.equal(await mockUSDC.getAddress());
      
      // Check that deadline is approximately correct
      // Use the escrow timestamp as base, not current block timestamp
      const expectedDeadline = Number(escrowData.timestamp) + 24 * 60 * 60; // ESCROW_PERIOD = 1 day (86400 seconds)
      expect(Number(escrowData.confirmationDeadline)).to.be.closeTo(expectedDeadline, 10);
      
      // In new structure, escrow doesn't have flags, just check that it exists
      expect(escrowData.commitment).to.equal(escrow.commitment);
      expect(Number((shield.flags >> 1n) & 1n)).to.equal(0); // spent flag

      // Check collected fees
      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(expectedFee);

      // Check escrow status
      const status = await contract.getEscrowStatus(escrow.commitment);
      expect(status).to.equal("Pending");
    });

    it("Should reject zero amounts", async function () {
      const amount = 0n;
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = await generateControlledCommitment(
        secret, 
        user1.address, 
        await contract.getAddress(), 
        block.timestamp, 
        block.prevrandao || ethers.ZeroHash, 
        0
      );
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), 100);

      // Сначала создаем shield с нулевой суммой, что должно вызывать ошибку
      await expect(
        contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
      ).to.be.revertedWithCustomError(contract, "ZeroAmount");
    });

    it("Should reject invalid token address", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = await generateControlledCommitment(
        secret, 
        user1.address, 
        await contract.getAddress(), 
        block.timestamp, 
        block.prevrandao || ethers.ZeroHash, 
        0
      );
      const bloomFilter = ethers.randomBytes(32);

      // Сначала создаем shield с нулевым адресом токена, что должно вызывать ошибку
      await expect(
        contract.connect(user1).shield(amount, ethers.ZeroAddress, commitment, bloomFilter)
      ).to.be.revertedWithCustomError(contract, "EmptyToken");
    });

    it("Should reject invalid commitment", async function () {
      const amount = ethers.parseUnits("100", 6);
      const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      // Пытаемся создать escrow с нулевым коммитментом
      await expect(
        contract.connect(user1).createEscrowShield(
          ethers.ZeroHash,
          encryptedSecret,
          bloomFilter
        )
      ).to.be.revertedWithCustomError(contract, "ShieldDoesNotExist");
    });

    it("Should reject duplicate commitments", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = await generateControlledCommitment(
        secret, 
        user1.address, 
        await contract.getAddress(), 
        block.timestamp, 
        block.prevrandao || ethers.ZeroHash, 
        0
      );
      const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount * 2n);

      // Создаем shield
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);

      // First escrow shield
      await contract.connect(user1).createEscrowShield(
        commitment,
        encryptedSecret,
        bloomFilter
      );

      // Try to create another escrow shield with same commitment
      await expect(
        contract.connect(user1).createEscrowShield(
          commitment,
          encryptedSecret,
          bloomFilter
        )
      ).to.be.revertedWithCustomError(contract, "CommitmentAlreadyExists");
    });

    it("Should reject empty encrypted secret", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = await generateControlledCommitment(
        secret, 
        user1.address, 
        await contract.getAddress(), 
        block.timestamp, 
        block.prevrandao || ethers.ZeroHash, 
        0
      );
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      // Создаем shield
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);

      // Пытаемся создать escrow с пустым encryptedSecret
      await expect(
        contract.connect(user1).createEscrowShield(
          commitment,
          "0x", // пустые данные
          bloomFilter
        )
      ).to.be.revertedWithCustomError(contract, "EncryptedSecretCannotBeEmpty");
    });

    it("Should create escrow shield with default confirmation period", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      // Check escrow info
      const [escrowData, shield] = await contract.getEscrowInfo(escrow.commitment);
      expect(escrowData.commitment).to.equal(escrow.commitment);
      
      // Check shield info
      expect(Number(shield.flags & 1n)).to.equal(1); // exists flag
      expect(Number((shield.flags >> 2n) & 1n)).to.equal(1); // isEscrow flag
      expect(shield.amount).to.be.gt(0);
      expect(shield.token).to.equal(await mockUSDC.getAddress());
      
      // Check that deadline is approximately correct (ESCROW_PERIOD = 1 day)
      // Use the escrow timestamp as base, not current block timestamp
      const expectedDeadline = Number(escrowData.timestamp) + 24 * 60 * 60; // 1 day (86400 seconds)
      expect(Number(escrowData.confirmationDeadline)).to.be.closeTo(expectedDeadline, 10);
    });

    it("Should reject when paused", async function () {
      await contract.connect(admin).pause();

      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = await generateControlledCommitment(
        secret, 
        user1.address, 
        await contract.getAddress(), 
        block.timestamp, 
        block.prevrandao || ethers.ZeroHash, 
        0
      );
      const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

      // Создаем shield
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);

      // Пытаемся создать escrow при паузе
      await expect(
        contract.connect(user1).createEscrowShield(
          commitment,
          encryptedSecret,
          bloomFilter
        )
      ).to.be.revertedWithCustomError(contract, "EnforcedPause");
    });

    it("Should handle zero fee correctly", async function () {
      // Set fees to zero
      await contract.connect(admin).setFees(0n, 0n, 0n);

      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      const [escrowData, shield] = await contract.getEscrowInfo(escrow.commitment);
      expect(shield.amount).to.equal(amount);
      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(0n);
    });
  });

  describe("Confirm Escrow", function () {
    let commitment, secret, amount, escrowData;

    beforeEach(async function () {
      amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);
      commitment = escrow.commitment;
      secret = escrow.secret;
      escrowData = escrow;
    });

    it("Should confirm escrow successfully", async function () {
      // Get user2 balance before confirmation
      const balanceBefore = await mockUSDC.balanceOf(user2.address);
      
      // Calculate expected fee and net amount
      const expectedFee = amount * UNSHIELD_FEE / FEE_DENOMINATOR;
      const expectedNetAmount = amount - expectedFee;

      await expect(contract.connect(user1).confirmEscrow(commitment, secret, user2.address))
        .to.emit(contract, "EscrowConfirmed")
        .withArgs(commitment, commitment)
        .to.emit(contract, "Unshielded")
        .withArgs(commitment, await mockUSDC.getAddress(), expectedNetAmount, expectedFee);

      // Check user2 balance after confirmation (should receive net amount)
      const balanceAfter = await mockUSDC.balanceOf(user2.address);
      expect(balanceAfter - balanceBefore).to.equal(expectedNetAmount);

      // Check escrow state
      const [escrow, shield] = await contract.getEscrowInfo(commitment);
      expect(escrow.commitment).to.equal(commitment);
      
      expect(shield.flags & 1).to.equal(1); // exists flag
      expect((shield.flags >> 1) & 1).to.equal(1); // spent flag

      // Check escrow status
      const status = await contract.getEscrowStatus(commitment);
      expect(status).to.equal("Confirmed");
    });

    it("Should reject confirmation from non-sender", async function () {
      await expect(
        contract.connect(user2).confirmEscrow(commitment, secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "InvalidCommitment");
    });

    it("Should reject confirmation of non-existent escrow", async function () {
      const nonExistentCommitment = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).confirmEscrow(nonExistentCommitment, secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should reject confirmation of regular shield", async function () {
      // Create regular shield
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = await generateControlledCommitment(
        secret, 
        user1.address, 
        await contract.getAddress(), 
        block.timestamp, 
        block.prevrandao || ethers.ZeroHash, 
        0
      );
      const bloomFilter = ethers.randomBytes(32);
      const amount = ethers.parseUnits("100", 6);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);

      await expect(
        contract.connect(user1).confirmEscrow(commitment, secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should reject double confirmation", async function () {
      // First confirmation
      await contract.connect(user1).confirmEscrow(commitment, secret, user2.address);

      // Try to confirm again
      await expect(
        contract.connect(user1).confirmEscrow(commitment, secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should reject confirmation after deadline", async function () {
      // Fast forward time beyond deadline
      await ethers.provider.send("evm_increaseTime", [24 * 60 * 60 + 1]); // 1 day + 1 second
      await ethers.provider.send("evm_mine", []);

      await expect(
        contract.connect(user1).confirmEscrow(commitment, secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "ConfirmationDeadlinePassed");
    });

    it("Should reject confirmation of cancelled escrow", async function () {
      // Fast forward time beyond minCancelTime
      await ethers.provider.send("evm_increaseTime", [3601]);
      await ethers.provider.send("evm_mine", []);
      
      // Cancel escrow first
      await contract.connect(user1).cancelEscrow(commitment, secret);

      // Try to confirm
      await expect(
        contract.connect(user1).confirmEscrow(commitment, secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should reject when paused", async function () {
      await contract.connect(admin).pause();

      await expect(
        contract.connect(user1).confirmEscrow(commitment, secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "EnforcedPause");
    });
  });

  describe("Cancel Escrow", function () {
    let commitment, secret, amount, expectedNetAmount;

    beforeEach(async function () {
      amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);
      commitment = escrow.commitment;
      secret = escrow.secret;
      
      const expectedFee = amount * UNSHIELD_FEE / FEE_DENOMINATOR;
      expectedNetAmount = amount - expectedFee;
    });

    it("Should cancel unconfirmed escrow successfully", async function () {
      // Fast forward time beyond minCancelTime
      await ethers.provider.send("evm_increaseTime", [3601]);
      await ethers.provider.send("evm_mine", []);
      
      const initialBalance = await mockUSDC.balanceOf(user1.address);

      await expect(contract.connect(user1).cancelEscrow(commitment, secret))
        .to.emit(contract, "EscrowCancelled")
        .withArgs(commitment, commitment, amount)
        .to.emit(contract, "Unshielded")
        .withArgs(commitment, await mockUSDC.getAddress(), expectedNetAmount, expectedFee);

      // Check user1 balance after cancellation (should receive net amount)
      const balanceAfter = await mockUSDC.balanceOf(user1.address);
      expect(balanceAfter - initialBalance).to.equal(expectedNetAmount);

      // Check escrow state
      const [escrow, shield] = await contract.getEscrowInfo(commitment);
      expect(escrow.commitment).to.equal(commitment);
      
      expect(shield.flags & 1).to.equal(1); // exists flag
      expect((shield.flags >> 1) & 1).to.equal(1); // spent flag

      // Check escrow status
      const status = await contract.getEscrowStatus(commitment);
      expect(status).to.equal("Cancelled");
    });

    it("Should reject cancel before minCancelTime", async function () {
      // Try to cancel immediately (should fail)
      await expect(
        contract.connect(user1).cancelEscrow(commitment, secret)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should cancel after minCancelTime", async function () {
      // Fast forward time to exactly minCancelTime
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine", []);
      
      const initialBalance = await mockUSDC.balanceOf(user1.address);

      await expect(contract.connect(user1).cancelEscrow(commitment, secret))
        .to.emit(contract, "EscrowCancelled")
        .withArgs(commitment, commitment, amount);

      // Check user1 balance after cancellation
      const balanceAfter = await mockUSDC.balanceOf(user1.address);
      expect(balanceAfter - initialBalance).to.equal(expectedNetAmount);
    });

    it("Should reject cancel with wrong secret", async function () {
      const wrongSecret = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).cancelEscrow(commitment, wrongSecret)
      ).to.be.revertedWithCustomError(contract, "InvalidCommitment");
    });

    it("Should reject cancel of non-existent escrow", async function () {
      const nonExistentCommitment = ethers.randomBytes(32);
      const randomSecret = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).cancelEscrow(nonExistentCommitment, randomSecret)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should reject cancel of regular shield", async function () {
      // Create regular shield
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = await generateControlledCommitment(
        secret, 
        user1.address, 
        await contract.getAddress(), 
        block.timestamp, 
        block.prevrandao || ethers.ZeroHash, 
        0
      );
      const bloomFilter = ethers.randomBytes(32);
      const amount = ethers.parseUnits("100", 6);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);

      await expect(
        contract.connect(user1).cancelEscrow(commitment, secret)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should reject cancel from non-sender", async function () {
      // Получаем информацию об эскроу, чтобы использовать правильное время
      const [escrowData] = await contract.getEscrowInfo(commitment);
      
      // Генерируем ожидаемый коммитмент с правильными параметрами
      const block = await ethers.provider.getBlock("latest");
      const expectedCommitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user2.address, escrowData.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), await contract.userNonces(user2.address)]
        )
      );
      
      // Проверяем, что коммитменты не совпадают
      expect(expectedCommitment).to.not.equal(commitment);
      
      await expect(
        contract.connect(user2).cancelEscrow(commitment, secret)
      ).to.be.revertedWithCustomError(contract, "InvalidCommitment");
    });

    it("Should reject cancel of confirmed escrow", async function () {
      // Confirm escrow first
      await contract.connect(user1).confirmEscrow(commitment, secret, user2.address);

      await expect(
        contract.connect(user1).cancelEscrow(commitment, secret)
      ).to.be.revertedWithCustomError(contract, "EscrowAlreadyConfirmed");
    });

    it("Should reject double cancel", async function () {
      // Fast forward time beyond minCancelTime
      await ethers.provider.send("evm_increaseTime", [3601]);
      await ethers.provider.send("evm_mine", []);
      
      // First cancel
      await contract.connect(user1).cancelEscrow(commitment, secret);

      // Try to cancel again
      await expect(
        contract.connect(user1).cancelEscrow(commitment, secret)
      ).to.be.revertedWithCustomError(contract, "EscrowAlreadyCancelled");
    });

    it("Should reject when paused", async function () {
      await contract.connect(admin).pause();

      await expect(
        contract.connect(user1).cancelEscrow(commitment, secret)
      ).to.be.revertedWithCustomError(contract, "EnforcedPause");
    });
  });

  describe("Escrow View Functions", function () {
    let commitment, secret, amount, expectedNetAmount;

    beforeEach(async function () {
      amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);
      commitment = escrow.commitment;
      secret = escrow.secret;
      
      const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR;
      expectedNetAmount = amount - expectedFee;
    });

    it("Should return correct escrow info", async function () {
      const [escrow, shield] = await contract.getEscrowInfo(commitment);

      expect(escrow.commitment).to.equal(commitment);
      
      expect(shield.flags & 1).to.equal(1); // exists flag
      expect((shield.flags >> 2) & 1).to.equal(1); // isEscrow flag
      expect(shield.token).to.equal(await mockUSDC.getAddress());
      expect(shield.amount).to.equal(expectedNetAmount);
      
      expect(shield.timestamp).to.be.gt(0);
      expect(escrow.confirmationDeadline).to.be.gt(shield.timestamp);
    });

    it("Should correctly identify active escrow", async function () {
      const isActive = await contract.isActiveEscrow(commitment);
      expect(isActive).to.be.true;

      // Cancel escrow
      await ethers.provider.send("evm_increaseTime", [3601]);
      await ethers.provider.send("evm_mine", []);
      await contract.connect(user1).cancelEscrow(commitment, secret);

      // Should no longer be active
      const isActiveAfterCancel = await contract.isActiveEscrow(commitment);
      expect(isActiveAfterCancel).to.be.false;
    });

    it("Should return correct status at different stages", async function () {
      // Initial status should be "Pending"
      let status = await contract.getEscrowStatus(commitment);
      expect(status).to.equal("Pending");

      // Confirm escrow
      await contract.connect(user1).confirmEscrow(commitment, secret, user2.address);

      // Status should be "Confirmed"
      status = await contract.getEscrowStatus(commitment);
      expect(status).to.equal("Confirmed");
    });

    it("Should return 'Expired' status after deadline", async function () {
      // Fast forward past deadline
      await ethers.provider.send("evm_increaseTime", [24 * 60 * 60 + 1]); // 1 day + 1 second
      await ethers.provider.send("evm_mine", []);

      const status = await contract.getEscrowStatus(commitment);
      expect(status).to.equal("Expired");
    });

    it("Should return 'Nonexistent' for non-existent escrow", async function () {
      const nonExistentCommitment = ethers.randomBytes(32);

      const status = await contract.getEscrowStatus(nonExistentCommitment);
      expect(status).to.equal("Nonexistent");

      const isActive = await contract.isActiveEscrow(nonExistentCommitment);
      expect(isActive).to.be.false;

      const [escrowInfo, shieldInfo] = await contract.getEscrowInfo(nonExistentCommitment);
      expect(escrowInfo.commitment).to.equal(ethers.ZeroHash);
      expect(shieldInfo.token).to.equal(ethers.ZeroAddress);
    });

    it("Should return 'Cancelled' status for cancelled escrow", async function () {
      // Cancel escrow
      await ethers.provider.send("evm_increaseTime", [3601]);
      await ethers.provider.send("evm_mine", []);
      await contract.connect(user1).cancelEscrow(commitment, secret);

      const status = await contract.getEscrowStatus(commitment);
      expect(status).to.equal("Cancelled");
    });
  });

  describe("Gas Optimization Tests", function () {
    it("Should use reasonable gas for escrow operations", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      // Test confirmEscrow gas
      const confirmTx = await contract.connect(user1).confirmEscrow(escrow.commitment, escrow.secret, user2.address);
      const confirmReceipt = await confirmTx.wait();
      console.log(`confirmEscrow gas used: ${confirmReceipt.gasUsed}`);

      // Gas should be reasonable (adjust based on actual implementation)
      expect(confirmReceipt.gasUsed).to.be.lt(200000n); // Less than 200k gas
    });

    it("Should use reasonable gas for createEscrowShield", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = await generateControlledCommitment(
        secret, 
        user1.address, 
        await contract.getAddress(), 
        block.timestamp, 
        block.prevrandao || ethers.ZeroHash, 
        0
      );
      const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);

      const tx = await contract.connect(user1).createEscrowShield(
        commitment, 
        encryptedSecret, 
        bloomFilter
      );
      const receipt = await tx.wait();
      console.log(`createEscrowShield gas used: ${receipt.gasUsed}`);

      // Gas should be reasonable (adjust based on actual implementation)
      expect(receipt.gasUsed).to.be.lt(300000n); // Less than 300k gas
    });
  });
});