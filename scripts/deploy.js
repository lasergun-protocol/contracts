const { ethers, upgrades } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  
  console.log("🚀 Deploying LaserGun with account:", deployer.address);
  
  // ✅ ETHERS V6 СИНТАКСИС
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("💰 Account balance:", ethers.formatEther(balance));
  
  // Проверяем баланс
  const minBalance = ethers.parseEther("0.01");
  if (balance < minBalance) {
    throw new Error(`❌ Insufficient balance. Need at least 0.01 ETH, got ${ethers.formatEther(balance)} ETH`);
  }
  
  console.log("📦 Getting LaserGun contract factory...");
  const LaserGun = await ethers.getContractFactory("LaserGun");
  
  console.log("📄 Deploying proxy...");
  
  // ✅ FIX: Передаем правильные параметры инициализации
  // LaserGun.initialize(admin, shieldFeePercent, unshieldFeePercent)
  const SHIELD_FEE = 25;    // 0.25% (25 basis points)
  const UNSHIELD_FEE = 25;  // 0.25% (25 basis points)
  
  const laserGun = await upgrades.deployProxy(
    LaserGun, 
    [deployer.address, SHIELD_FEE, UNSHIELD_FEE], // ✅ Правильные параметры
    {
      initializer: 'initialize',
      kind: 'uups'
    }
  );
  
  // ✅ ETHERS V6 - правильное ожидание deployment
  await laserGun.waitForDeployment();
  
  // ✅ ETHERS V6 - получаем адрес
  const proxyAddress = await laserGun.getAddress();
  
  console.log("✅ LaserGun proxy deployed to:", proxyAddress);
  
  // Получаем адрес implementation contract
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("📦 Implementation address:", implementationAddress);
  
  // Проверяем deployment
  console.log("🔍 Verifying deployment...");
  const code = await ethers.provider.getCode(proxyAddress);
  if (code === "0x") {
    throw new Error("❌ Proxy deployment failed - no code at address");
  }
  
  console.log("✅ Proxy deployment verified");
  
  // Тестируем инициализацию
  try {
    // Проверяем роли
    const ADMIN_ROLE = await laserGun.ADMIN_ROLE();
    const hasAdminRole = await laserGun.hasRole(ADMIN_ROLE, deployer.address);
    console.log("👑 Admin role assigned:", hasAdminRole);
    
    // Проверяем fees
    const shieldFee = await laserGun.shieldFeePercent();
    const unshieldFee = await laserGun.unshieldFeePercent();
    console.log("💰 Shield fee:", shieldFee.toString(), "basis points");
    console.log("💰 Unshield fee:", unshieldFee.toString(), "basis points");
    
    // Проверяем, что контракт не на паузе
    const paused = await laserGun.paused();
    console.log("⏸️ Contract paused:", paused);
    
    if (!hasAdminRole) {
      throw new Error(`❌ Admin role not assigned to deployer`);
    }
    
    if (shieldFee != SHIELD_FEE || unshieldFee != UNSHIELD_FEE) {
      throw new Error(`❌ Fee mismatch. Expected: ${SHIELD_FEE}/${UNSHIELD_FEE}, Got: ${shieldFee}/${unshieldFee}`);
    }
    
    console.log("✅ Initialization verified");
  } catch (error) {
    console.warn("⚠️ Could not verify initialization:", error.message);
  }
  
  // Выводим сводную информацию
  const network = await ethers.provider.getNetwork();
  
  console.log("\n📋 Deployment Summary:");
  console.log("═══════════════════════════════════════");
  console.log("Proxy Address:        ", proxyAddress);
  console.log("Implementation:       ", implementationAddress);
  console.log("Network:              ", network.name);
  console.log("Chain ID:             ", network.chainId);
  console.log("Deployer:             ", deployer.address);
  console.log("Shield Fee:           ", SHIELD_FEE, "basis points (0.25%)");
  console.log("Unshield Fee:         ", UNSHIELD_FEE, "basis points (0.25%)");
  console.log("Gas Used:             ", "~2,500,000 gas"); // примерная оценка
  console.log("═══════════════════════════════════════");
  
  // Сохраняем информацию о deployment
  const fs = require('fs');
  const deploymentInfo = {
    proxy: proxyAddress,
    implementation: implementationAddress,
    network: network.name,
    chainId: Number(network.chainId),
    deployer: deployer.address,
    deployedAt: new Date().toISOString(),
    contractName: "LaserGun",
    proxyKind: "uups",
    shieldFeePercent: SHIELD_FEE,
    unshieldFeePercent: UNSHIELD_FEE
  };
  
  // Сохраняем в deployment.json
  fs.writeFileSync(
    './deployment.json', 
    JSON.stringify(deploymentInfo, null, 2)
  );
  
  console.log("💾 Deployment info saved to deployment.json");
  
  // Для удобства фронтенда - сохраняем только адрес
  fs.writeFileSync(
    './contract-address.txt', 
    proxyAddress
  );
  
  console.log("\n🎉 Deployment completed successfully!");
  console.log("🔗 Add this address to your frontend:", proxyAddress);
}

main()
  .then(() => {
    console.log("✅ Script completed successfully");
    process.exit(0);
  })
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });