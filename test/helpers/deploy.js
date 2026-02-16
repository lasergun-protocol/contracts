const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

// Загружаем адреса библиотек из файла
function loadLibraryAddresses() {
  try {
    const libraryAddressesPath = path.join(__dirname, "../../library-addresses.json");
    const libraryAddresses = JSON.parse(fs.readFileSync(libraryAddressesPath, "utf8"));
    return libraryAddresses;
  } catch (error) {
    console.error("Ошибка при загрузке адресов библиотек:", error);
    return null;
  }
}

async function deployLibraries() {
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

  return {
    ShieldOperations: await shieldOperations.getAddress(),
    EscrowOperations: await escrowOperations.getAddress(),
    Utils: await utils.getAddress(),
    ShieldFlags: await shieldFlags.getAddress()
  };
}

async function deployLaserGunWithLibraries(adminAddress, shieldFee, unshieldFee, transferFee) {
  // Пытаемся загрузить адреса библиотек из файла
  let libraries = loadLibraryAddresses();
  
  // Если файл не найден или пустой, деплоим библиотеки
  if (!libraries) {
    console.log("Адреса библиотек не найдены, деплоим новые...");
    libraries = await deployLibraries();
  }
  
  // Include only libraries that LaserGun uses directly
  const laserGunLibraries = {
    EscrowOperations: libraries.EscrowOperations,
    Utils: libraries.Utils
  };
  
  // Deploy LaserGun with linked libraries
  const LaserGun = await ethers.getContractFactory("contracts/LaserGun.sol:LaserGun", {
    libraries: laserGunLibraries
  });
  
  const contract = await upgrades.deployProxy(
    LaserGun,
    [adminAddress, Number(shieldFee), Number(unshieldFee), Number(transferFee)],
    {
      initializer: 'initialize',
      kind: 'uups',
      timeout: 60000,
      unsafeAllowLinkedLibraries: true
    }
  );
  
  await contract.waitForDeployment();
  return contract;
}

module.exports = {
  deployLibraries,
  deployLaserGunWithLibraries,
  loadLibraryAddresses
};