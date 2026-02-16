// test/LaserGun.escrow.basic.test.js - Базовый тест escrow-функциональности
const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun Escrow - Basic Functionality", function () {
  let contract, mockUSDC;
  let admin, user1, user2;

  const SHIELD_FEE = 25n;
  const UNSHIELD_FEE = 25n;
  const TRANSFER_FEE = 25n;
  const FEE_DENOMINATOR = 10000n;

  before(async function () {
    await network.provider.send("hardhat_reset", []);
  });

  beforeEach(async function () {
    [admin, user1, user2] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6, 0, false);
    await mockUSDC.waitForDeployment();

    const amount = ethers.parseUnits("10000", 6);
    await mockUSDC.mint(user1.address, amount);
    await mockUSDC.mint(user2.address, amount);

    contract = await deployLaserGunWithLibraries(
      admin.address,
      SHIELD_FEE,
      UNSHIELD_FEE,
      TRANSFER_FEE
    );
    await network.provider.send("evm_mine", []);
  });

  async function waitForTransaction(txPromise) {
    const tx = await txPromise;
    const receipt = await tx.wait();
    await network.provider.send("evm_mine", []);
    return receipt;
  }

  it("Should create and confirm escrow shield with manual commitment verification", async function () {
    const amount = ethers.parseUnits("100", 6);
    const secret = ethers.randomBytes(32);
    
    // Получаем текущие данные блока
    const block = await ethers.provider.getBlock("latest");
    const timestamp = block.timestamp;
    const prevrandao = block.prevrandao || ethers.ZeroHash;
    const contractAddress = await contract.getAddress();
    
    // Получаем текущий nonce пользователя
    const nonce = await contract.userNonces(user1.address);
    
    // Генерируем коммитмент вручную
    const commitment = ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user1.address, timestamp, prevrandao, contractAddress, nonce]
      )
    );
    
    const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
    const bloomFilter = ethers.randomBytes(32);

    // Создаем shield с дополнительными токенами для комиссии
    const totalAmount = amount + (amount * SHIELD_FEE / FEE_DENOMINATOR);
    await mockUSDC.connect(user1).approve(contractAddress, totalAmount);
    await waitForTransaction(
      contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
    );
    
    // Создаем escrow
    await waitForTransaction(
      contract.connect(user1).createEscrowShield(
        commitment,
        encryptedSecret,
        bloomFilter
      )
    );

    // Проверяем, что escrow создан
    const [escrowData, shield] = await contract.getEscrowInfo(commitment);
    expect(escrowData.commitment).to.equal(commitment);
    expect(Number(shield.flags & 1n)).to.equal(1); // exists flag
    expect(Number((shield.flags >> 2n) & 1n)).to.equal(1); // isEscrow flag

    // Проверяем статус
    const status = await contract.getEscrowStatus(commitment);
    expect(status).to.equal("Pending");

    // Проверяем, что escrow активен
    const isActive = await contract.isActiveEscrow(commitment);
    expect(isActive).to.be.true;
  });

  it("Should reject escrow operations with invalid commitments", async function () {
    const amount = ethers.parseUnits("100", 6);
    const secret = ethers.randomBytes(32);
    
    // Создаем shield с правильным коммитментом
    const block = await ethers.provider.getBlock("latest");
    const contractAddress = await contract.getAddress();
    const commitment = ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, contractAddress, 0]
      )
    );
    
    const bloomFilter = ethers.randomBytes(32);
    await mockUSDC.connect(user1).approve(contractAddress, amount);
    await waitForTransaction(
      contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
    );

    // Пытаемся создать escrow с неправильным коммитментом
    const wrongCommitment = ethers.randomBytes(32);
    const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
    
    await expect(
      contract.connect(user1).createEscrowShield(
        wrongCommitment,
        encryptedSecret,
        bloomFilter
      )
    ).to.be.revertedWithCustomError(contract, "ShieldDoesNotExist");
  });

  it("Should handle escrow deadline correctly", async function () {
    const amount = ethers.parseUnits("100", 6);
    const secret = ethers.randomBytes(32);
    
    const block = await ethers.provider.getBlock("latest");
    const contractAddress = await contract.getAddress();
    const commitment = ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, contractAddress, 0]
      )
    );
    
    const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);
    const bloomFilter = ethers.randomBytes(32);

    await mockUSDC.connect(user1).approve(contractAddress, amount);
    await waitForTransaction(
      contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
    );
    
    await waitForTransaction(
      contract.connect(user1).createEscrowShield(
        commitment,
        encryptedSecret,
        bloomFilter
      )
    );

    // Проверяем дедлайн
    const [escrowData] = await contract.getEscrowInfo(commitment);
    const expectedDeadline = Number(escrowData.timestamp) + 24 * 60 * 60; // 1 день
    expect(Number(escrowData.confirmationDeadline)).to.be.closeTo(expectedDeadline, 10);

    // Перемещаем время за пределы дедлайна
    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60 + 1]); // 1 день + 1 секунда
    await ethers.provider.send("evm_mine", []);

    // Проверяем статус
    const status = await contract.getEscrowStatus(commitment);
    expect(status).to.equal("Expired");
  });

  it("Should handle escrow view functions correctly", async function () {
    // Тестируем с несуществующим коммитментом
    const nonExistentCommitment = ethers.randomBytes(32);
    
    const status = await contract.getEscrowStatus(nonExistentCommitment);
    expect(status).to.equal("Nonexistent");

    const isActive = await contract.isActiveEscrow(nonExistentCommitment);
    expect(isActive).to.be.false;

    const [escrowInfo, shieldInfo] = await contract.getEscrowInfo(nonExistentCommitment);
    expect(escrowInfo.commitment).to.equal(ethers.ZeroHash);
    expect(shieldInfo.token).to.equal(ethers.ZeroAddress);
  });
});