// scripts/verify.js
const { run, network } = require("hardhat");

/**
 * Verifies the ServiceAgreement implementation contract on Etherscan
 */
async function main() {
  console.log(`Verifying ServiceAgreement implementation on ${network.name}...`);

  // Skip verification on local networks
  if (network.name === "hardhat" || network.name === "localhost") {
    console.log("Skipping verification on local network");
    return;
  }

  // Get the implementation address
  const implementationAddress = process.env.IMPLEMENTATION_ADDRESS || getImplementationAddress(network.name);
  
  if (!implementationAddress) {
    console.error("No implementation address provided. Set the IMPLEMENTATION_ADDRESS environment variable.");
    process.exit(1);
  }
  
  console.log(`Verifying implementation at: ${implementationAddress}`);
  
  try {
    // Run the verify task
    await run("verify:verify", {
      address: implementationAddress,
      constructorArguments: [],
    });
    
    console.log(`Verification successful for implementation at ${implementationAddress}`);
  } catch (error) {
    if (error.message.includes("already verified")) {
      console.log("Contract is already verified!");
    } else {
      console.error("Verification failed:", error);
    }
  }
}

/**
 * Returns network-specific implementation addresses
 * These should be updated after each deployment or upgrade
 */
function getImplementationAddress(networkName) {
  const addresses = {
    // Replace with actual implementation addresses
    sepolia: "0xYOUR_SEPOLIA_IMPLEMENTATION_ADDRESS",
    mainnet: "0xYOUR_MAINNET_IMPLEMENTATION_ADDRESS",
  };
  
  return addresses[networkName];
}

// Execute verification
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 