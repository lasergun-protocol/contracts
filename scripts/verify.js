const { ethers, run, network } = require("hardhat");
const fs = require("fs");

async function main() {
  console.log("🔍 Starting contract verification process...");
  
  // Получаем информацию о deployment из файла
  let deploymentInfo;
  try {
    deploymentInfo = JSON.parse(fs.readFileSync("./deployment.json", "utf8"));
    console.log("📄 Found deployment info:", deploymentInfo);
  } catch (error) {
    console.error("❌ Could not read deployment.json. Please deploy the contract first.");
    process.exit(1);
  }
  
  // Получаем текущую сеть
  const currentNetwork = await ethers.provider.getNetwork();
  const networkName = network.name;
  
  console.log(`🌐 Verifying on network: ${networkName} (Chain ID: ${currentNetwork.chainId})`);
  
  // Проверяем, что deployment был на той же сети
  if (deploymentInfo.chainId !== Number(currentNetwork.chainId)) {
    console.error(`❌ Network mismatch. Deployment was on Chain ID: ${deploymentInfo.chainId}, current network: ${currentNetwork.chainId}`);
    process.exit(1);
  }
  
  const proxyAddress = deploymentInfo.proxy;
  const implementationAddress = deploymentInfo.implementation;
  
  console.log(`📍 Proxy Address: ${proxyAddress}`);
  console.log(`📦 Implementation Address: ${implementationAddress}`);
  
  // Проверяем, что адреса существуют
  if (!proxyAddress || !implementationAddress) {
    console.error("❌ Missing contract addresses in deployment info");
    process.exit(1);
  }
  
  // Проверяем, что API ключ установлен
  const requiredEnvVars = getRequiredEnvVars(networkName);
  const missingEnvVars = requiredEnvVars.filter(envVar => !process.env[envVar]);
  
  if (missingEnvVars.length > 0) {
    console.error(`❌ Missing required environment variables: ${missingEnvVars.join(", ")}`);
    console.error("💡 Please add these variables to your .env file");
    process.exit(1);
  }
  
  try {
    // Верифицируем implementation контракт
    console.log("🔍 Verifying implementation contract...");
    
    await run("verify:verify", {
      address: implementationAddress,
      constructorArguments: [], // Implementation контракт не имеет конструктора
    });
    
    console.log("✅ Implementation contract verified successfully!");
    
    // Для прокси контракта верификация не требуется, так как это стандартный прокси
    // Но мы можем проверить, что прокси указывает на правильный implementation
    console.log("🔍 Verifying proxy points to correct implementation...");
    
    const actualImplementation = await ethers.provider.getStorageAt(
      proxyAddress,
      "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc" // EIP1967 implementation slot
    );
    
    // Адрес хранится в storage, но в формате 32 байтов, поэтому нужно извлечь последние 20 байтов
    const extractedImplementation = "0x" + actualImplementation.slice(-40);
    
    if (extractedImplementation.toLowerCase() === implementationAddress.toLowerCase()) {
      console.log("✅ Proxy correctly points to implementation");
    } else {
      console.error("❌ Proxy does not point to the expected implementation");
      console.error(`Expected: ${implementationAddress}`);
      console.error(`Actual: ${extractedImplementation}`);
      process.exit(1);
    }
    
    // Обновляем deployment.json с информацией о верификации
    deploymentInfo.verified = true;
    deploymentInfo.verifiedAt = new Date().toISOString();
    deploymentInfo.verifiedOn = networkName;
    
    fs.writeFileSync(
      './deployment.json',
      JSON.stringify(deploymentInfo, null, 2)
    );
    
    console.log("💾 Updated deployment.json with verification info");
    
    // Выводим ссылки на обозреватель блоков
    const explorerUrls = getExplorerUrls(networkName);
    if (explorerUrls) {
      console.log("\n🔗 Explorer Links:");
      console.log(`Proxy: ${explorerUrls.base}/address/${proxyAddress}`);
      console.log(`Implementation: ${explorerUrls.base}/address/${implementationAddress}`);
    }
    
    console.log("\n🎉 Verification completed successfully!");
    
  } catch (error) {
    if (error.message.includes("Already Verified")) {
      console.log("✅ Contract is already verified");
    } else {
      console.error("❌ Verification failed:", error.message);
      process.exit(1);
    }
  }
}

// Вспомогательные функции
function getRequiredEnvVars(networkName) {
  switch (networkName) {
    case "polygon":
    case "amoy":
      return ["POLYGONSCAN_API_KEY"];
    case "avalanche":
    case "avalancheFujiTestnet":
      return ["SNOWTRACE_API_KEY"];
    default:
      return [];
  }
}

function getExplorerUrls(networkName) {
  switch (networkName) {
    case "polygon":
      return { base: "https://polygonscan.com" };
    case "amoy":
      return { base: "https://amoy.polygonscan.com" };
    case "avalanche":
      return { base: "https://snowtrace.io" };
    case "avalancheFujiTestnet":
      return { base: "https://testnet.snowtrace.io" };
    default:
      return null;
  }
}

main()
  .then(() => {
    console.log("✅ Verification script completed successfully");
    process.exit(0);
  })
  .catch((error) => {
    console.error("❌ Verification script failed:", error);
    process.exit(1);
  });