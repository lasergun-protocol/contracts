const { ethers } = require("hardhat");

async function main() {
  // Deploy libraries
  const ShieldOperations = await ethers.getContractFactory("ShieldOperations");
  const shieldOperations = await ShieldOperations.deploy();
  await shieldOperations.waitForDeployment();
  console.log("ShieldOperations deployed to:", await shieldOperations.getAddress());

  const EscrowOperations = await ethers.getContractFactory("EscrowOperations");
  const escrowOperations = await EscrowOperations.deploy();
  await escrowOperations.waitForDeployment();
  console.log("EscrowOperations deployed to:", await escrowOperations.getAddress());

  const Utils = await ethers.getContractFactory("Utils");
  const utils = await Utils.deploy();
  await utils.waitForDeployment();
  console.log("Utils deployed to:", await utils.getAddress());

  const ShieldFlags = await ethers.getContractFactory("ShieldFlags");
  const shieldFlags = await ShieldFlags.deploy();
  await shieldFlags.waitForDeployment();
  console.log("ShieldFlags deployed to:", await shieldFlags.getAddress());

  // Save library addresses to a file for use in tests
  const libraryAddresses = {
    ShieldOperations: await shieldOperations.getAddress(),
    EscrowOperations: await escrowOperations.getAddress(),
    Utils: await utils.getAddress(),
    ShieldFlags: await shieldFlags.getAddress()
  };

  const fs = require("fs");
  fs.writeFileSync(
    "./library-addresses.json",
    JSON.stringify(libraryAddresses, null, 2)
  );
  console.log("Library addresses saved to library-addresses.json");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });