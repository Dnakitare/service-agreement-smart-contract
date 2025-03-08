const { ethers, upgrades, network } = require("hardhat");

/**
 * Main deployment script for ServiceAgreement contract
 */
async function main() {
  console.log(`Deploying ServiceAgreement to ${network.name}...`);

  // Get deployment parameters
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer address: ${deployer.address}`);

  // Get network-specific configuration
  const config = getNetworkConfig(network.name);
  
  // Deploy ServiceAgreement contract
  const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement");
  
  console.log("Deploying ServiceAgreement proxy...");
  const serviceAgreement = await upgrades.deployProxy(
    ServiceAgreement, 
    [config.arbitrator, config.feeCollector],
    { kind: 'uups' }
  );
  
  await serviceAgreement.waitForDeployment();
  const serviceAgreementAddress = await serviceAgreement.getAddress();
  
  console.log(`ServiceAgreement proxy deployed to: ${serviceAgreementAddress}`);
  console.log(`Implementation address: ${await upgrades.erc1967.getImplementationAddress(serviceAgreementAddress)}`);
  
  // Configure whitelisted tokens
  if (config.whitelistedTokens && config.whitelistedTokens.length > 0) {
    console.log("Adding whitelisted tokens...");
    
    for (const token of config.whitelistedTokens) {
      console.log(`Adding token ${token} to whitelist...`);
      await serviceAgreement.addWhitelistedToken(token);
      console.log(`Token whitelist action scheduled for ${token}`);
    }
    
    console.log("Note: You need to wait for the timelock period and execute the whitelist actions later");
  }
  
  // Set arbitrator pool if available
  if (config.arbitratorPool && config.arbitratorPool.length > 0) {
    console.log("Setting arbitrator pool...");
    await serviceAgreement.setArbitratorPool(config.arbitratorPool);
    console.log("Arbitrator pool set");
  }
  
  // Create templates
  if (config.templates && config.templates.length > 0) {
    console.log("Creating agreement templates...");
    
    for (const template of config.templates) {
      console.log(`Creating template: ${template.name}`);
      await serviceAgreement.createTemplate(
        template.name,
        template.terms,
        template.recommendedDuration,
        template.recommendedMilestones
      );
      console.log(`Template created: ${template.name}`);
    }
  }
  
  console.log("Deployment complete!");
  
  // Return deployment information for use in verification scripts
  return {
    serviceAgreement: serviceAgreementAddress,
    arbitrator: config.arbitrator,
    feeCollector: config.feeCollector
  };
}

/**
 * Returns network-specific configuration
 */
function getNetworkConfig(networkName) {
  const oneDay = 24 * 60 * 60;
  const oneWeek = 7 * oneDay;
  const oneMonth = 30 * oneDay;
  
  // Default templates
  const defaultTemplates = [
    {
      name: "Basic Agreement",
      terms: "Standard terms for a simple service agreement.",
      recommendedDuration: oneMonth,
      recommendedMilestones: 3
    },
    {
      name: "Website Development",
      terms: "Terms for website development project.",
      recommendedDuration: 2 * oneMonth,
      recommendedMilestones: 5
    },
    {
      name: "Smart Contract Audit",
      terms: "Terms for a smart contract security audit.",
      recommendedDuration: 3 * oneWeek,
      recommendedMilestones: 2
    }
  ];
  
  // Network configurations
  const configs = {
    // Local development
    hardhat: {
      arbitrator: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", // Hardhat account #1
      feeCollector: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", // Hardhat account #2
      arbitratorPool: [
        "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", // Hardhat account #1
        "0x90F79bf6EB2c4f870365E785982E1f101E93b906", // Hardhat account #3
        "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"  // Hardhat account #4
      ],
      templates: defaultTemplates,
      whitelistedTokens: []
    },
    
    // Testnet
    sepolia: {
      arbitrator: "0xYOUR_ARBITRATOR_ADDRESS_HERE",
      feeCollector: "0xYOUR_FEE_COLLECTOR_ADDRESS_HERE",
      arbitratorPool: [
        "0xYOUR_ARBITRATOR_ADDRESS_HERE",
        "0xANOTHER_ARBITRATOR_ADDRESS_HERE"
      ],
      templates: defaultTemplates,
      whitelistedTokens: [
        "0xYOUR_TEST_TOKEN_ADDRESS_HERE"  // Example: USDC on Sepolia
      ]
    },
    
    // Mainnet
    mainnet: {
      arbitrator: "0xYOUR_MAINNET_ARBITRATOR_ADDRESS",
      feeCollector: "0xYOUR_MAINNET_FEE_COLLECTOR_ADDRESS",
      arbitratorPool: [
        "0xYOUR_MAINNET_ARBITRATOR_ADDRESS",
        "0xANOTHER_MAINNET_ARBITRATOR_ADDRESS"
      ],
      templates: defaultTemplates,
      whitelistedTokens: [
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",  // USDC
        "0xdAC17F958D2ee523a2206206994597C13D831ec7"   // USDT
      ]
    }
  };
  
  // Return config for the specific network or default to hardhat
  return configs[networkName] || configs.hardhat;
}

// Execute deployment
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 