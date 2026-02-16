"use strict";
const { ethers } = require("hardhat");
const fs = require('fs');
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("🪙 Deploying TestToken with account:", deployer.address);
    // Проверяем баланс
    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("💰 Account balance:", ethers.formatEther(balance));
    const minBalance = ethers.parseEther("0.005"); // Меньше чем для LaserGun
    if (balance < minBalance) {
        throw new Error(`❌ Insufficient balance. Need at least 0.005 ETH, got ${ethers.formatEther(balance)} ETH`);
    }
    // Параметры тестового токена
    const tokenParams = {
        name: "Test USDC",
        symbol: "TUSDC",
        decimals: 6, // Как у настоящего USDC
        initialSupply: 1000000 // 1M токенов владельцу
    };
    console.log("📦 Token parameters:");
    console.log("  Name:", tokenParams.name);
    console.log("  Symbol:", tokenParams.symbol);
    console.log("  Decimals:", tokenParams.decimals);
    console.log("  Initial Supply:", tokenParams.initialSupply);
    // Deploy TestToken
    console.log("🚀 Deploying TestToken...");
    const TestToken = await ethers.getContractFactory("TestToken");
    const testToken = await TestToken.deploy(tokenParams.name, tokenParams.symbol, tokenParams.decimals, tokenParams.initialSupply);
    await testToken.waitForDeployment();
    const tokenAddress = await testToken.getAddress();
    console.log("✅ TestToken deployed to:", tokenAddress);
    // Проверяем deployment
    console.log("🔍 Verifying deployment...");
    const name = await testToken.name();
    const symbol = await testToken.symbol();
    const decimals = await testToken.decimals();
    const totalSupply = await testToken.totalSupply();
    const deployerBalance = await testToken.balanceOf(deployer.address);
    console.log("📋 Token Info:");
    console.log("  Name:", name);
    console.log("  Symbol:", symbol);
    console.log("  Decimals:", decimals);
    console.log("  Total Supply:", ethers.formatUnits(totalSupply, decimals));
    console.log("  Deployer Balance:", ethers.formatUnits(deployerBalance, decimals));
    // Тестируем faucet
    console.log("🚿 Testing faucet...");
    try {
        const faucetTx = await testToken.faucet();
        await faucetTx.wait();
        const newBalance = await testToken.balanceOf(deployer.address);
        console.log("  Faucet works! New balance:", ethers.formatUnits(newBalance, decimals));
    }
    catch (error) {
        console.warn("  Faucet test failed:", error.message);
    }
    // Получаем network info
    const network = await ethers.provider.getNetwork();
    // Сохраняем информацию о токене
    const tokenInfo = {
        address: tokenAddress,
        name: tokenParams.name,
        symbol: tokenParams.symbol,
        decimals: tokenParams.decimals,
        totalSupply: ethers.formatUnits(totalSupply, decimals),
        network: network.name,
        chainId: Number(network.chainId),
        deployer: deployer.address,
        deployedAt: new Date().toISOString(),
        faucetAmount: "1000", // 1000 токенов за запрос
        faucetCooldown: "1 hour",
        contractName: "TestToken"
    };
    // Сохраняем в отдельный файл
    fs.writeFileSync('./test-token.json', JSON.stringify(tokenInfo, null, 2));
    console.log("💾 Token info saved to test-token.json");
    // Добавляем в основной deployment.json если он существует
    try {
        const deploymentData = JSON.parse(fs.readFileSync('./deployment.json', 'utf8'));
        deploymentData.testToken = tokenInfo;
        fs.writeFileSync('./deployment.json', JSON.stringify(deploymentData, null, 2));
        console.log("💾 Token info added to deployment.json");
    }
    catch (error) {
        console.log("ℹ️ deployment.json not found, token info saved separately");
    }
    // Выводим инструкции
    console.log("\n📋 Deployment Summary:");
    console.log("═══════════════════════════════════════");
    console.log("Token Address:        ", tokenAddress);
    console.log("Network:              ", network.name);
    console.log("Chain ID:             ", network.chainId);
    console.log("Deployer:             ", deployer.address);
    console.log("═══════════════════════════════════════");
    console.log("\n🎯 Next Steps:");
    console.log("1. Add token to MetaMask:");
    console.log("   Address:", tokenAddress);
    console.log("   Symbol: TUSDC");
    console.log("   Decimals: 6");
    console.log("");
    console.log("2. Get test tokens from faucet:");
    console.log("   Call testToken.faucet() to get 1000 TUSDC");
    console.log("   Cooldown: 1 hour between claims");
    console.log("");
    console.log("3. Use with LaserGun:");
    console.log("   - Approve LaserGun to spend your tokens");
    console.log("   - Use deposit() to create Shields");
    console.log("   - Test anonymous transfers");
    // Если LaserGun уже задеплоен, покажем пример транзакций
    try {
        const deploymentData = JSON.parse(fs.readFileSync('./deployment.json', 'utf8'));
        if (deploymentData.proxy) {
            console.log("");
            console.log("4. LaserGun Integration:");
            console.log("   LaserGun Address:", deploymentData.proxy);
            console.log("   Example approve:", `testToken.approve("${deploymentData.proxy}", amount)`);
            console.log("   Example deposit: ", `laserGun.deposit(amount, "${tokenAddress}", commitment)`);
        }
    }
    catch (error) {
        // LaserGun не задеплоен или нет файла - не проблема
    }
    console.log("\n🎉 TestToken deployment completed!");
}
main()
    .then(() => {
    console.log("✅ Token deployment script completed successfully");
    process.exit(0);
})
    .catch((error) => {
    console.error("❌ Token deployment failed:", error);
    process.exit(1);
});
//# sourceMappingURL=deploy-test-token.js.map