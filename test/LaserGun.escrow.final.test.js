// test/LaserGun.escrow.final.test.js - Финальная исправленная версия escrow-тестов
const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun Escrow", function () {
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
    
    // Получаем текущие данные блока для генерации коммитмента
    const block = await ethers.provider.getBlock("latest");
    const timestamp = block.timestamp || Math.floor(Date.now() / 1000);
    const prevrandao = block.prevrandao || ethers.ZeroHash;
    const contractAddress = await contract.getAddress();
    const nonce = 0; // Начальный nonce для нового пользователя
    
    // Генерируем коммитмент вручную с сохраненными значениями блока
    const commitment = ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user.address, timestamp, prevrandao, contractAddress, nonce]
      )
    );
    
    const bloomFilter = ethers.randomBytes(32); // 32 байта bloom filter
    const tokenAddress = typeof token === 'string' ? token : await token.getAddress();
    
    await token.connect(user).approve(contractAddress, amount);
    await waitForTransaction(
      contract.connect(user).shield(amount, tokenAddress, commitment, bloomFilter)
    );

    return { secret, commitment, amount, bloomFilter, timestamp, prevrandao, nonce };
  }

  async function createTestEscrowShield(user, amount, recipient, token = mockUSDC) {
    const secret = ethers.randomBytes(32);
    
    // Получаем текущие данные блока для генерации коммитмента
    const block = await ethers.provider.getBlock("latest");
    const timestamp = block.timestamp || Math.floor(Date.now() / 1000);
    const prevrandao = block.prevrandao || ethers.ZeroHash;
    const contractAddress = await contract.getAddress();
    const nonce = 0; // Начальный nonce для нового пользователя
    
    // Генерируем коммитмент вручную с сохраненными значениями блока
    const commitment = ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user.address, timestamp, prevrandao, contractAddress, nonce]
      )
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

    return { secret, commitment, amount, bloomFilter, recipient, encryptedSecret, timestamp, prevrandao, nonce };
  }

  describe("Create Escrow Shield", function () {
    it("Should create escrow shield successfully", async function () {
      const amount = ethers.parseUnits("100", 6);
      const { secret, commitment, bloomFilter, recipient } = await createTestEscrowShield(
        user1,
        amount,
        user2.address
      );

      // Calculate expected fee and net amount
      const expectedFee = amount * SHIELD_FEE / FEE_DENOMINATOR;
      const expectedNetAmount = amount - expectedFee;

      // Check escrow info
      const [escrow, shield] = await contract.getEscrowInfo(commitment);
      expect(escrow.commitment).to.equal(commitment);
      
      // Check shield info
      expect(Number(shield.flags & 1n)).to.equal(1); // exists flag
      expect(Number((shield.flags >> 2n) & 1n)).to.equal(1); // isEscrow flag
      expect(shield.amount).to.equal(expectedNetAmount);
      expect(shield.token).to.equal(await mockUSDC.getAddress());
      
      // Check that deadline is approximately correct
      // Use the escrow timestamp as base, not current block timestamp
      const expectedDeadline = Number(escrow.timestamp) + 24 * 60 * 60; // ESCROW_PERIOD = 1 day (86400 seconds)
      expect(Number(escrow.confirmationDeadline)).to.be.closeTo(expectedDeadline, 10);
      
      // In new structure, escrow doesn't have flags, just check that it exists
      expect(escrow.commitment).to.equal(commitment);
      expect(Number((shield.flags >> 1n) & 1n)).to.equal(0); // spent flag

      // Check collected fees
      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(expectedFee);

      // Check escrow status
      const status = await contract.getEscrowStatus(commitment);
      expect(status).to.equal("Pending");
    });

    it("Should reject zero amounts", async function () {
      const amount = 0n;
      const secret = ethers.randomBytes(32);
      const commitment = await contract.generateCommitment(secret, user1.address);
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
      const commitment = await contract.generateCommitment(secret, user1.address);
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
      const commitment = await contract.generateCommitment(secret, user1.address);
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
      const commitment = await contract.generateCommitment(secret, user1.address);
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
      const commitment = await contract.generateCommitment(secret, user1.address);
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
    let commitment, secret, amount, senderCommitment;

    beforeEach(async function () {
      amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);
      commitment = escrow.commitment;
      secret = escrow.secret;
      
      // Get the sender commitment from the escrow
      const [escrowData, shield] = await contract.getEscrowInfo(commitment);
      senderCommitment = escrowData.commitment;
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
      const regularShield = await createTestShield(user1, amount);

      await expect(
        contract.connect(user1).confirmEscrow(regularShield.commitment, regularShield.secret, user2.address)
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
      const regularShield = await createTestShield(user1, amount);

      await expect(
        contract.connect(user1).cancelEscrow(regularShield.commitment, regularShield.secret)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should reject cancel from non-sender", async function () {
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

  describe("Integration with Regular Shield Functions", function () {
    it("Should reject direct unshield of escrow shield", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      await expect(
        contract.connect(user1).unshield(escrow.secret, amount, user3.address, ethers.randomBytes(32))
      ).to.be.revertedWithCustomError(contract, "CannotUnshieldEscrowDirectly");
    });

    it("Should reject direct transfer of escrow shield", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);
      const recipientCommitment = ethers.randomBytes(32);
      const encryptedSecret = ethers.hexlify(ethers.randomBytes(64));
      const bloomFilter = ethers.randomBytes(32);

      await expect(
        contract.connect(user1).transfer(
          escrow.secret,
          amount,
          recipientCommitment,
          encryptedSecret,
          bloomFilter
        )
      ).to.be.revertedWithCustomError(contract, "CannotTransferEscrowDirectly");
    });

    it("Should maintain backward compatibility with regular shields", async function () {
      // Create regular shield
      const amount = ethers.parseUnits("100", 6);
      const regularShield = await createTestShield(user1, amount);

      // Verify regular shield works normally
      const shieldInfo = await contract.getShieldInfo(regularShield.commitment);
      expect(shieldInfo.exists).to.be.true;
      expect(shieldInfo.amount).to.equal(amount - amount * SHIELD_FEE / FEE_DENOMINATOR);

      // Verify it's not an escrow
      const isActiveEscrow = await contract.isActiveEscrow(regularShield.commitment);
      expect(isActiveEscrow).to.be.false;

      // Regular unshield should work
      const newCommitment = ethers.randomBytes(32);
      const netAmount = amount - amount * SHIELD_FEE / FEE_DENOMINATOR;
      await expect(
        contract.connect(user1).unshield(regularShield.secret, netAmount, user2.address, newCommitment)
      ).to.emit(contract, "Unshielded");
    });

    it("Should handle both regular and escrow shields simultaneously", async function () {
      // Create regular shield
      const regularAmount = ethers.parseUnits("100", 6);
      const regularShield = await createTestShield(user1, regularAmount);

      // Create escrow shield
      const escrowAmount = ethers.parseUnits("200", 6);
      const escrowData = await createTestEscrowShield(user1, escrowAmount, user2.address);

      // Verify both exist
      const regularShieldInfo = await contract.getShieldInfo(regularShield.commitment);
      expect(regularShieldInfo.exists).to.be.true;

      const [escrowInfo, shield] = await contract.getEscrowInfo(escrowData.commitment);
      expect(shield.flags & 1).to.equal(1); // exists flag
      expect((shield.flags >> 2) & 1).to.equal(1); // isEscrow flag

      // Verify different statuses
      const isActiveRegularEscrow = await contract.isActiveEscrow(regularShield.commitment);
      expect(isActiveRegularEscrow).to.be.false;

      const isActiveEscrow = await contract.isActiveEscrow(escrowData.commitment);
      expect(isActiveEscrow).to.be.true;

      // Operations on regular shield should work
      const newCommitment = ethers.randomBytes(32);
      const netRegularAmount = regularAmount - regularAmount * SHIELD_FEE / FEE_DENOMINATOR;
      await contract.connect(user1).unshield(regularShield.secret, netRegularAmount, user3.address, newCommitment);

      // Operations on escrow should work
      await contract.connect(user1).confirmEscrow(escrowData.commitment, escrowData.secret, user2.address);
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

  describe("Security Tests", function () {
    it("Should prevent unauthorized access to escrow operations", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      // User3 should not be able to confirm
      await expect(
        contract.connect(user3).confirmEscrow(escrow.commitment, escrow.secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "InvalidCommitment");
    });

    it("Should prevent replay attacks", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      // Confirm escrow
      await contract.connect(user1).confirmEscrow(escrow.commitment, escrow.secret, user2.address);

      // Try to confirm again (replay attack)
      await expect(
        contract.connect(user1).confirmEscrow(escrow.commitment, escrow.secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should handle edge cases with timing", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      // Confirm escrow
      await contract.connect(user1).confirmEscrow(escrow.commitment, escrow.secret, user2.address);

      // Fast forward to just before deadline
      await ethers.provider.send("evm_increaseTime", [24 * 60 * 60 - 1]); // 1 day - 1 second
      await ethers.provider.send("evm_mine", []);

      // Should still be able to confirm (funds already released)
      await expect(
        contract.connect(user1).confirmEscrow(escrow.commitment, escrow.secret, user2.address)
      ).to.be.revertedWithCustomError(contract, "InvalidEscrowState");
    });

    it("Should handle multiple escrows for same users", async function () {
      const amount = ethers.parseUnits("100", 6);

      // Create multiple escrows
      const escrow1 = await createTestEscrowShield(user1, amount, user2.address);
      const escrow2 = await createTestEscrowShield(user1, amount, user2.address);
      const escrow3 = await createTestEscrowShield(user1, amount, user3.address);

      // Confirm all escrows
      await contract.connect(user1).confirmEscrow(escrow1.commitment, escrow1.secret, user2.address);
      await contract.connect(user1).confirmEscrow(escrow2.commitment, escrow2.secret, user2.address);
      await contract.connect(user1).confirmEscrow(escrow3.commitment, escrow3.secret, user3.address);

      // Check final balances
      const user2Balance = await mockUSDC.balanceOf(user2.address);
      const user3Balance = await mockUSDC.balanceOf(user3.address);
      
      const expectedNetAmount = amount - amount * SHIELD_FEE / FEE_DENOMINATOR;
      
      // Users start with 10000 tokens, so we need to check the increase from that
      const initialBalance = ethers.parseUnits("10000", 6);
      expect(user2Balance - initialBalance).to.equal(expectedNetAmount * 2n); // Two escrows for user2
      expect(user3Balance - initialBalance).to.equal(expectedNetAmount); // One escrow for user3
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
      const commitment = await contract.generateCommitment(secret, user1.address);
      const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);

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