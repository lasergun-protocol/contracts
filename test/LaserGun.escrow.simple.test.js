// test/LaserGun.escrow.simple.test.js - Упрощенный тест escrow-функциональности
const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun Escrow - Simple Test", function () {
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

    // Deploy MockERC20
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6, 0, false);
    await mockUSDC.waitForDeployment();

    // Mint tokens to users
    const amount = ethers.parseUnits("10000", 6);
    await mockUSDC.mint(user1.address, amount);
    await mockUSDC.mint(user2.address, amount);

    // Deploy LaserGun proxy with libraries
    contract = await deployLaserGunWithLibraries(admin.address, SHIELD_FEE, UNSHIELD_FEE, TRANSFER_FEE);
    
    await network.provider.send("evm_mine", []);
  });

  async function waitForTransaction(txPromise) {
    const tx = await txPromise;
    const receipt = await tx.wait();
    await network.provider.send("evm_mine", []);
    return receipt;
  }

  it("Should create shield successfully", async function () {
    const amount = ethers.parseUnits("100", 6);
    const secret = ethers.randomBytes(32);
    
    // Generate commitment
    const block = await ethers.provider.getBlock("latest");
    const commitment = ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
      )
    );
    
    const bloomFilter = ethers.randomBytes(32);

    // Create shield
    await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
    await waitForTransaction(
      contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
    );

    // Check shield info
    const [exists, token, shieldAmount, timestamp, spent] = await contract.getShieldInfo(commitment);
    expect(exists).to.be.true;
    expect(token).to.equal(await mockUSDC.getAddress());
    // The shield amount should be the original amount minus the fee
    const expectedAmount = amount - (amount * SHIELD_FEE / FEE_DENOMINATOR);
    expect(shieldAmount).to.equal(expectedAmount);
    expect(spent).to.be.false;
  });

  it("Should create escrow shield from existing shield", async function () {
    const amount = ethers.parseUnits("100", 6);
    const secret = ethers.randomBytes(32);
    
    // Generate commitment
    const block = await ethers.provider.getBlock("latest");
    const commitment = ethers.keccak256(
      ethers.solidityPacked(
        ["bytes32", "address", "uint256", "uint256", "address", "uint256"],
        [secret, user1.address, block.timestamp, block.prevrandao || ethers.ZeroHash, await contract.getAddress(), 0]
      )
    );
    
    const bloomFilter = ethers.randomBytes(32);
    const encryptedSecret = ethers.solidityPacked(["string"], ["encrypted_secret_data"]);

    // Create shield
    await mockUSDC.connect(user1).approve(await contract.getAddress(), amount);
    await waitForTransaction(
      contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter)
    );
    
    // Create escrow
    await waitForTransaction(
      contract.connect(user1).createEscrowShield(
        commitment,
        encryptedSecret,
        bloomFilter
      )
    );

    // Check escrow info
    const [escrowData, shield] = await contract.getEscrowInfo(commitment);
    expect(escrowData.commitment).to.equal(commitment);
    expect(escrowData.creator).to.equal(user1.address);
    
    // Check that shield is marked as escrow
    const isActive = await contract.isActiveEscrow(commitment);
    expect(isActive).to.be.true;
  });
});