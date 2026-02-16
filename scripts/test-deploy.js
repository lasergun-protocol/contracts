const { ethers } = require("hardhat");

async function main() {
  // Deploy libraries
  const ShieldOperations = await ethers.getContractFactory("ShieldOperations");
  const shieldOperations = await ShieldOperations.deploy();
  await shieldOperations.waitForDeployment();

  const EscrowOperations = await ethers.getContractFactory("EscrowOperations");
  const escrowOperations = await EscrowOperations.deploy();
  await escrowOperations.waitForDeployment();

  const Utils = await ethers.getContractFactory("Utils");
  const utils = await Utils.deploy();
  await utils.waitForDeployment();

  const ShieldFlags = await ethers.getContractFactory("ShieldFlags");
  const shieldFlags = await ShieldFlags.deploy();
  await shieldFlags.waitForDeployment();

  // Deploy MockERC20
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6, 0, false);
  await mockUSDC.waitForDeployment();

  // Deploy LaserGun with linked libraries
  const LaserGun = await ethers.getContractFactory("LaserGun", {
    libraries: {
      ShieldOperations: await shieldOperations.getAddress(),
      EscrowOperations: await escrowOperations.getAddress(),
      Utils: await utils.getAddress()
    }
  });
  
  const contract = await LaserGun.deploy();
  await contract.waitForDeployment();
  
  // Initialize contract
  const [admin] = await ethers.getSigners();
  await contract.initialize(admin.address, 25, 25, 25);
  
  console.log("LaserGun deployed to:", await contract.getAddress());
  console.log("MockUSDC deployed to:", await mockUSDC.getAddress());
  
  return { contract, mockUSDC };
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });