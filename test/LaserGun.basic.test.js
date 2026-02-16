// test/LaserGun.basic.test.js - Базовый тест функциональности
const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { deployLaserGunWithLibraries } = require("./helpers/deploy");

describe("LaserGun - Basic Functionality", function () {
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

    // Deploy LaserGun with proper library linking
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
    // Check fee settings (contract is already initialized)
    expect(await contract.shieldFeePercent()).to.equal(SHIELD_FEE);
    expect(await contract.unshieldFeePercent()).to.equal(UNSHIELD_FEE);
    expect(await contract.transferFeePercent()).to.equal(TRANSFER_FEE);
  });
});