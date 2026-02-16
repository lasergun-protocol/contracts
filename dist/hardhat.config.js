"use strict";
require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-ethers"); // ethers v6
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        version: "0.8.24", // Обновленная версия Solidity
        settings: {
            optimizer: {
                enabled: true,
                runs: 200,
            },
        },
    },
    networks: {
        hardhat: {
            accounts: {
                count: 20,
                accountsBalance: "10000000000000000000000", // 10k ETH each
            },
        },
        localhost: {
            url: "http://127.0.0.1:8545",
        },
        polygon: {
            url: process.env.POLYGON_RPC_URL || "https://polygon-rpc.com",
            accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
        },
        amoy: {
            url: process.env.AMOY_RPC_URL || "https://rpc-amoy.polygon.technology",
            accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
            chainId: 80002,
        },
        avalanche: {
            url: process.env.AVALANCHE_RPC_URL || "https://avalanche-c-chain-rpc.publicnode.com",
            accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
            chainId: 43114,
        }
    },
    etherscan: {
        apiKey: {
            polygon: process.env.POLYGONSCAN_API_KEY,
            amoy: process.env.POLYGONSCAN_API_KEY,
            avalanche: process.env.SNOWTRACE_API_KEY, // Добавлен API ключ для Avalanche
            avalancheFujiTestnet: process.env.SNOWTRACE_API_KEY, // Для тестовой сети Fuji
        },
        customChains: [
            {
                network: "amoy",
                chainId: 80002,
                urls: {
                    apiURL: "https://api-amoy.polygonscan.com/api",
                    browserURL: "https://amoy.polygonscan.com"
                }
            },
            {
                network: "avalanche",
                chainId: 43114,
                urls: {
                    apiURL: "https://api.snowtrace.io/api",
                    browserURL: "https://snowtrace.io"
                }
            },
            {
                network: "avalancheFujiTestnet",
                chainId: 43113,
                urls: {
                    apiURL: "https://api-testnet.snowtrace.io/api",
                    browserURL: "https://testnet.snowtrace.io"
                }
            }
        ]
    },
    gasReporter: {
        enabled: process.env.REPORT_GAS !== undefined,
        currency: "USD",
        gasPrice: 30,
        coinmarketcap: process.env.COINMARKETCAP_API_KEY,
    },
    mocha: {
        timeout: 60000,
    },
};
//# sourceMappingURL=hardhat.config.js.map