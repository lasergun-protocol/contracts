// test/LaserGun.test.simple.js - Базовый тест функциональности
const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun - Simple Test", function () {
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

    // Deploy LaserGun with libraries
    contract = await deployLaserGunWithLibraries(admin.address, SHIELD_FEE, UNSHIELD_FEE, TRANSFER_FEE);
    
    await network.provider.send("evm_mine", []);
  });

  it("Should have correct initial state", async function () {
    // Check that contract is already initialized
    expect(await contract.hasRole(await contract.DEFAULT_ADMIN_ROLE(), admin.address)).to.be.true;
  });

  it("Should generate commitment correctly", async function () {
    const secret = ethers.randomBytes(32);
    const commitment = await contract.generateCommitment(secret, user1.address);
    
    // Check that commitment is not empty
    expect(commitment).to.not.equal(ethers.ZeroHash);
    
    // Check that commitment is deterministic for same inputs
    const commitment2 = await contract.generateCommitment(secret, user1.address);
    expect(commitment).to.equal(commitment2);
  });

  it("Should have correct fee settings", async function () {
    // Contract is already initialized in deployLaserGunWithLibraries
    
    // Check fee settings
    expect(await contract.shieldFeePercent()).to.equal(SHIELD_FEE);
    expect(await contract.unshieldFeePercent()).to.equal(UNSHIELD_FEE);
    expect(await contract.transferFeePercent()).to.equal(TRANSFER_FEE);
  });

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
    const tx = await contract.connect(user1).shield(amount, await mockUSDC.getAddress(), commitment, bloomFilter);
    await tx.wait();
    
    // Check shield info
    const [exists, token, shieldAmount, timestamp, spent] = await contract.getShieldInfo(commitment);
    expect(exists).to.be.true;
    expect(token).to.equal(await mockUSDC.getAddress());
    // The shield amount should be the original amount minus the fee
    const expectedAmount = amount - (amount * SHIELD_FEE / FEE_DENOMINATOR);
    expect(shieldAmount).to.equal(expectedAmount);
    expect(spent).to.be.false;
  });
});