require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("solidity-docgen");

const REPORT_GAS = process.env.REPORT_GAS === "true";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      },
      viaIR: true,
      outputSelection: {
        "*": {
          "*": ["abi", "evm.bytecode", "evm.deployedBytecode", "metadata", "storageLayout"]
        }
      }
    },
  },
  networks: {
    hardhat: {
      chainId: 31337
    }
  },
  docgen: {
    outputDir: "docs/api",
    pages: "single",
    exclude: ["test"],
    pageExtension: ".md"
  },
  gasReporter: {
    enabled: REPORT_GAS,
    currency: "USD",
    noColors: true,
    outputFile: REPORT_GAS ? "gas-report.txt" : undefined,
    excludeContracts: ["MockERC20", "MockTokenWithFee", "EthRefuser"]
  }
};
