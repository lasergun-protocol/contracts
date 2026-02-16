"use strict";
const { ethers, upgrades } = require("hardhat");
const fs = require('fs');
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("🔄 Upgrading LaserGun with account:", deployer.address);
    // ✅ ETHERS V6 СИНТАКСИС
    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("💰 Account balance:", ethers.formatEther(balance));
    // Проверяем баланс
    const minBalance = ethers.parseEther("0.005"); // upgrade дешевле чем deploy
    if (balance < minBalance) {
        throw new Error(`❌ Insufficient balance. Need at least 0.005 ETH, got ${ethers.formatEther(balance)} ETH`);
    }
    // Читаем адрес proxy из deployment.json
    let proxyAddress, deploymentInfo;
    try {
        deploymentInfo = JSON.parse(fs.readFileSync('./deployment.json', 'utf8'));
        proxyAddress = deploymentInfo.proxy;
        console.log("📋 Found proxy address:", proxyAddress);
    }
    catch (error) {
        throw new Error("❌ Could not read deployment.json. Run deploy script first.");
    }
    if (!proxyAddress) {
        throw new Error("❌ No proxy address found in deployment.json");
    }
    // Проверяем, что proxy существует
    const code = await ethers.provider.getCode(proxyAddress);
    if (code === "0x") {
        throw new Error(`❌ No contract found at proxy address: ${proxyAddress}`);
    }
    console.log("📦 Getting LaserGun contract factory...");
    const LaserGunV2 = await ethers.getContractFactory("LaserGun");
    // Получаем текущий implementation address
    const currentImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("📄 Current implementation:", currentImpl);
    console.log("🚀 Upgrading contract...");
    // ✅ ETHERS V6 + OpenZeppelin Upgrades
    const upgraded = await upgrades.upgradeProxy(proxyAddress, LaserGunV2
    /* , {
    unsafeAllow: [
        'storage-layout-error',
        'state-variable-reorder',
        'state-variable-assignment',
        'constructor',
        'delegatecall',
        'selfdestruct',
        'missing-public-upgradeto',
        'external-library-linking'
    ],
    unsafeAllowCustomTypes: true,
    unsafeSkipStorageCheck: true,
    unsafeAllowLinkedLibraries: true
} */ );
    // ✅ ETHERS V6 - правильное ожидание upgrade
    await upgraded.waitForDeployment();
    // ✅ ETHERS V6 - получаем адрес (должен быть тот же)
    const upgradedAddress = await upgraded.getAddress();
    if (upgradedAddress.toLowerCase() !== proxyAddress.toLowerCase()) {
        throw new Error(`❌ Proxy address changed! Expected: ${proxyAddress}, Got: ${upgradedAddress}`);
    }
    // Получаем новый implementation address
    const newImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("✅ LaserGun upgraded successfully!");
    console.log("📦 New implementation:", newImpl);
    // Проверяем, что implementation действительно изменился
    if (currentImpl.toLowerCase() === newImpl.toLowerCase()) {
        console.warn("⚠️ Warning: Implementation address didn't change. No upgrade needed?");
    }
    else {
        console.log("✅ Implementation successfully updated");
    }
    // Тестируем upgrade
    try {
        console.log("🔍 Testing upgraded contract...");
        // ✅ Проверяем admin роль вместо owner (LaserGun использует AccessControl, не Ownable)
        const ADMIN_ROLE = await upgraded.ADMIN_ROLE();
        const hasAdminRole = await upgraded.hasRole(ADMIN_ROLE, deployer.address);
        console.log("👑 Admin role assigned:", hasAdminRole);
        // Проверяем, что контракт не на паузе
        const paused = await upgraded.paused();
        console.log("⏸️ Contract paused:", paused);
        // Если есть новые функции в V2, тестируем их
        try {
            // Пример: если добавили новую функцию version()
            const version = await upgraded.version();
            console.log("📝 Contract version:", version);
        }
        catch (error) {
            // Функция version может не существовать - это нормально
            console.log("📝 No version function found (normal for V1)");
        }
        // Проверяем, что все роли настроены правильно
        const DEFAULT_ADMIN_ROLE = await upgraded.DEFAULT_ADMIN_ROLE();
        const FEE_MANAGER_ROLE = await upgraded.FEE_MANAGER_ROLE();
        const PAUSER_ROLE = await upgraded.PAUSER_ROLE();
        const UPGRADER_ROLE = await upgraded.UPGRADER_ROLE();
        const hasDefaultAdmin = await upgraded.hasRole(DEFAULT_ADMIN_ROLE, deployer.address);
        const hasFeeManager = await upgraded.hasRole(FEE_MANAGER_ROLE, deployer.address);
        const hasPauser = await upgraded.hasRole(PAUSER_ROLE, deployer.address);
        const hasUpgrader = await upgraded.hasRole(UPGRADER_ROLE, deployer.address);
        console.log("🔐 Role check:");
        console.log("  - DEFAULT_ADMIN_ROLE:", hasDefaultAdmin);
        console.log("  - ADMIN_ROLE:", hasAdminRole);
        console.log("  - FEE_MANAGER_ROLE:", hasFeeManager);
        console.log("  - PAUSER_ROLE:", hasPauser);
        console.log("  - UPGRADER_ROLE:", hasUpgrader);
        if (!hasAdminRole || !hasUpgrader) {
            throw new Error("❌ Critical roles not assigned to deployer");
        }
        console.log("✅ Upgrade verification completed");
    }
    catch (error) {
        console.error("❌ Upgrade verification failed:", error.message);
        throw error;
    }
    // Обновляем deployment info
    const network = await ethers.provider.getNetwork();
    // Добавляем информацию об upgrade
    const upgradeInfo = {
        upgradedAt: new Date().toISOString(),
        upgrader: deployer.address,
        previousImplementation: currentImpl,
        newImplementation: newImpl,
        network: network.name,
        chainId: Number(network.chainId)
    };
    if (!deploymentInfo.upgrades) {
        deploymentInfo.upgrades = [];
    }
    deploymentInfo.upgrades.push(upgradeInfo);
    deploymentInfo.currentImplementation = newImpl;
    deploymentInfo.lastUpgraded = upgradeInfo.upgradedAt;
    deploymentInfo.implementation = newImpl; // Обновляем основной implementation адрес
    fs.writeFileSync('./deployment.json', JSON.stringify(deploymentInfo, null, 2));
    // Выводим сводную информацию
    console.log("\n📋 Upgrade Summary:");
    console.log("═══════════════════════════════════════");
    console.log("Proxy Address:        ", proxyAddress);
    console.log("Old Implementation:   ", currentImpl);
    console.log("New Implementation:   ", newImpl);
    console.log("Network:              ", network.name);
    console.log("Chain ID:             ", network.chainId);
    console.log("Upgrader:             ", deployer.address);
    console.log("Upgrade Status:       ", currentImpl === newImpl ? "No changes" : "Success");
    console.log("═══════════════════════════════════════");
    console.log("💾 Upgrade info saved to deployment.json");
    console.log("\n🎉 Upgrade completed successfully!");
    console.log("🔗 Contract address remains:", proxyAddress);
}
main()
    .then(() => {
    console.log("✅ Upgrade script completed successfully");
    process.exit(0);
})
    .catch((error) => {
    console.error("❌ Upgrade failed:", error);
    process.exit(1);
});
//# sourceMappingURL=upgrade.js.map