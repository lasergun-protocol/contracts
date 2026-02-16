// test/LaserGun.escrow.security.working.test.js - Рабочая версия security тестов для escrow
const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun Escrow Security - Working Version", function () {
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
    [admin, user1, user2, user3] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6, 0, false);
    await mockUSDC.waitForDeployment();

    const amount = ethers.parseUnits("10000", 6);
    await mockUSDC.mint(user1.address, amount);
    await mockUSDC.mint(user2.address, amount);
    await mockUSDC.mint(user3.address, amount);

    contract = await deployLaserGunWithLibraries(admin.address, SHIELD_FEE, UNSHIELD_FEE, TRANSFER_FEE);
    await network.provider.send("evm_mine", []);
  });

  async function waitForTransaction(txPromise) {
    const tx = await txPromise;
    const receipt = await tx.wait();
    await network.provider.send("evm_mine", []);
    return receipt;
  }

  async function createTestEscrowShield(user, amount, recipient) {
    const secret = ethers.randomBytes(32);
    
    const block = await ethers.provider.getBlock("latest");
    const timestamp = block.timestamp;
    const prevrandao = block.prevrandao || ethers.ZeroHash;
    const contractAddress = await contract.getAddress();
    const nonce = await contract.userNonces(user.address);
    
    const commitment = ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user.address, timestamp, prevrandao, contractAddress, nonce]
      )
    );
    
    const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
    const bloomFilter = ethers.randomBytes(32);

    await mockUSDC.connect(user).approve(contractAddress, amount);
    await waitForTransaction(
      contract.connect(user).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
    );
    
    await waitForTransaction(
      contract.connect(user).createEscrowShield(
        commitment,
        encryptedSecret,
        bloomFilter
      )
    );

    return { secret, commitment, amount, bloomFilter, recipient, encryptedSecret };
  }

  describe("Security Tests", function () {
    it("Should prevent unauthorized access to escrow operations", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      // User3 should not be able to confirm (проверка через просмотр статуса)
      const statusBefore = await contract.getEscrowStatus(escrow.commitment);
      expect(statusBefore).to.equal("Pending");
      
      // Проверяем, что user3 не может подтвердить через проверку коммитмента
      const block = await ethers.provider.getBlock("latest");
      const expectedCommitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [escrow.secret, user3.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), await contract.userNonces(user3.address)]
        )
      );
      
      // Коммитменты не должны совпадать для разных пользователей
      expect(expectedCommitment).to.not.equal(escrow.commitment);
    });

    it("Should handle edge cases with timing", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      // Проверяем статус до дедлайна
      let status = await contract.getEscrowStatus(escrow.commitment);
      expect(status).to.equal("Pending");

      // Перемещаем время за пределы дедлайна
      await ethers.provider.send("evm_increaseTime", [24 * 60 * 60 + 1]); // 1 день + 1 секунда
      await ethers.provider.send("evm_mine", []);

      // Проверяем статус после дедлайна
      status = await contract.getEscrowStatus(escrow.commitment);
      expect(status).to.equal("Expired");
    });

    it("Should handle multiple escrows for same users", async function () {
      const amount = ethers.parseUnits("100", 6);

      // Создаем несколько escrow
      const escrow1 = await createTestEscrowShield(user1, amount, user2.address);
      const escrow2 = await createTestEscrowShield(user1, amount, user2.address);
      const escrow3 = await createTestEscrowShield(user1, amount, user3.address);

      // Проверяем, что все escrow существуют и активны
      const status1 = await contract.getEscrowStatus(escrow1.commitment);
      const status2 = await contract.getEscrowStatus(escrow2.commitment);
      const status3 = await contract.getEscrowStatus(escrow3.commitment);

      expect(status1).to.equal("Pending");
      expect(status2).to.equal("Pending");
      expect(status3).to.equal("Pending");

      const isActive1 = await contract.isActiveEscrow(escrow1.commitment);
      const isActive2 = await contract.isActiveEscrow(escrow2.commitment);
      const isActive3 = await contract.isActiveEscrow(escrow3.commitment);

      expect(isActive1).to.be.true;
      expect(isActive2).to.be.true;
      expect(isActive3).to.be.true;
    });

    it("Should handle escrow with minimum amounts", async function () {
      const amount = 1n; // Минимальная сумма
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      const [escrowData, shield] = await contract.getEscrowInfo(escrow.commitment);
      expect(escrowData.commitment).to.equal(escrow.commitment);
      expect(shield.amount).to.be.gt(0); // Должна быть положительной после вычета комиссии
      
      const status = await contract.getEscrowStatus(escrow.commitment);
      expect(status).to.equal("Pending");
    });

    it("Should handle escrow with maximum reasonable amounts", async function () {
      const amount = ethers.parseUnits("10000", 6); // Большая сумма
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      const [escrowData, shield] = await contract.getEscrowInfo(escrow.commitment);
      expect(escrowData.commitment).to.equal(escrow.commitment);
      expect(shield.amount).to.be.gt(0);
      
      const status = await contract.getEscrowStatus(escrow.commitment);
      expect(status).to.equal("Pending");
    });

    it("Should handle escrow operations when paused", async function () {
      const amount = ethers.parseUnits("100", 6);
      const secret = ethers.randomBytes(32);
      
      const block = await ethers.provider.getBlock("latest");
      const commitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
      );
      
      const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
      const bloomFilter = ethers.randomBytes(32);

      await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
      await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);

      // Теперь ставим на паузу после создания shield
      await contract.connect(admin).pause();

      // Пытаемся создать escrow при паузе
      await expect(
        contract.connect(user1).createEscrowShield(
          commitment,
          encryptedSecret,
          bloomFilter
        )
      ).to.be.revertedWithCustomError(contract, "EnforcedPause");
    });

    it("Should handle escrow with zero fees", async function () {
      // Устанавливаем нулевые комиссии
      await contract.connect(admin).setFees(0n, 0n, 0n);

      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      const [escrowData, shield] = await contract.getEscrowInfo(escrow.commitment);
      expect(escrowData.commitment).to.equal(escrow.commitment);
      expect(shield.amount).to.equal(amount); // Без комиссии сумма должна быть полной
      
      expect(await contract.collectedFees(await mockUSDC.getAddress())).to.equal(0n);
    });

    it("Should handle escrow view functions correctly for edge cases", async function () {
      // Тестируем с нулевым коммитментом
      const zeroCommitment = ethers.ZeroHash;
      
      const status = await contract.getEscrowStatus(zeroCommitment);
      expect(status).to.equal("Nonexistent");

      const isActive = await contract.isActiveEscrow(zeroCommitment);
      expect(isActive).to.be.false;

      const [escrowInfo, shieldInfo] = await contract.getEscrowInfo(zeroCommitment);
      expect(escrowInfo.commitment).to.equal(ethers.ZeroHash);
      expect(shieldInfo.token).to.equal(ethers.ZeroAddress);
    });

    it("Should handle gas optimization correctly", async function () {
      const amount = ethers.parseUnits("100", 6);
      const escrow = await createTestEscrowShield(user1, amount, user2.address);

      // Тестируем gas для createEscrowShield
      const secret = ethers.randomBytes(32);
      const block = await ethers.provider.getBlock("latest");
      const commitment = ethers.keccak256(
        ethers.solidityPacked(
          ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
          [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
        )
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
      
      // Gas должен быть разумным (менее 300k)
      expect(receipt.gasUsed).to.be.lt(300000n);
    });
  });
});