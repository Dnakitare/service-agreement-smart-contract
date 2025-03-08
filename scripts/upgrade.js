// scripts/upgrade.js
const { ethers, upgrades, network } = require("hardhat");

/**
 * Main upgrade script for ServiceAgreement contract
 * This script will upgrade an existing proxy to a new implementation
 */
async function main() {
  console.log(`Upgrading ServiceAgreement on ${network.name}...`);

  // Get the proxy address from command line or environment variables
  const proxyAddress = process.env.PROXY_ADDRESS || getProxyAddress(network.name);
  
  if (!proxyAddress) {
    console.error("No proxy address provided. Set the PROXY_ADDRESS environment variable.");
    process.exit(1);
  }
  
  console.log(`Using proxy address: ${proxyAddress}`);
  
  // Deploy new implementation
  const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement");
  console.log("Deploying new implementation...");
  
  // Prepare the upgrade
  const upgraded = await upgrades.upgradeProxy(proxyAddress, ServiceAgreement);
  await upgraded.waitForDeployment();
  
  const newImplementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log(`Upgrade successful!`);
  console.log(`Proxy address: ${proxyAddress}`);
  console.log(`New implementation address: ${newImplementationAddress}`);
  
  return {
    proxy: proxyAddress,
    implementation: newImplementationAddress
  };
}

/**
 * Returns network-specific proxy addresses
 * These should be updated after each deployment
 */
function getProxyAddress(networkName) {
  const addresses = {
    // Replace with actual deployed addresses
    hardhat: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    sepolia: "0xYOUR_SEPOLIA_PROXY_ADDRESS",
    mainnet: "0xYOUR_MAINNET_PROXY_ADDRESS",
  };
  
  return addresses[networkName];
}

// Execute upgrade
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 