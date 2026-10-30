import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: {
          optimizer: { enabled: true, runs: 50 },
          viaIR: true,
        },
      },
      production: {
        version: "0.8.28",
        settings: {
          optimizer: { enabled: true, runs: 50 },
          viaIR: true,
        },
      },
    },
  },
  // Robinhood Chain is an Arbitrum Orbit L2 compiled for cancun. Mainnet sources are verified on Etherscan
  // (robin.etherscan.io through the Etherscan API v2) and Blockscout; the testnet on its Blockscout.
  chainDescriptors: {
    46630: {
      name: "Robinhood Testnet",
      chainType: "generic",
      hardforkHistory: { cancun: { blockNumber: 0 } },
      blockExplorers: {
        blockscout: {
          name: "Robinhood Testnet Explorer",
          url: "https://explorer.testnet.chain.robinhood.com",
          apiUrl: "https://explorer.testnet.chain.robinhood.com/api",
        },
      },
    },
    4663: {
      name: "Robinhood Mainnet",
      chainType: "generic",
      hardforkHistory: { cancun: { blockNumber: 0 } },
      blockExplorers: {
        etherscan: {
          name: "Robinhood Chain Etherscan",
          url: "https://robin.etherscan.io",
          apiUrl: "https://api.etherscan.io/v2/api",
        },
        blockscout: {
          name: "Robinhood Chain Blockscout",
          url: "https://robinhoodchain.blockscout.com",
          apiUrl: "https://robinhoodchain.blockscout.com/api",
        },
      },
    },
  },
  verify: {
    etherscan: { apiKey: configVariable("ETHERSCAN_API_KEY") },
  },
  networks: {
    robinhoodTestnet: {
      type: "http",
      chainType: "generic",
      chainId: 46630,
      url: "https://rpc.testnet.chain.robinhood.com/rpc",
      accounts: [configVariable("ROBINHOOD_TESTNET_PRIVATE_KEY")],
    },
    robinhoodMainnet: {
      type: "http",
      chainType: "generic",
      chainId: 4663,
      url: "https://rpc.mainnet.chain.robinhood.com/rpc",
      accounts: [configVariable("ROBINHOOD_MAINNET_PRIVATE_KEY")],
    },
  },
});
