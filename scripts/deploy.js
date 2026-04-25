const { ethers, upgrades, network } = require("hardhat");

/**
 * Deploys the ServiceAgreement UUPS proxy.
 *
 * Post-deploy actions that touch privileged config (whitelisting tokens,
 * rotating the arbitrator pool) are scheduled via the timelock and must be
 * executed after TIMELOCK_DELAY (2 days). This script schedules them; the
 * `executeAction` calls are intentionally left as a manual follow-up.
 */
async function main() {
  console.log(`Deploying ServiceAgreement to ${network.name}...`);

  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  const config = getNetworkConfig(network.name);

  const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement");
  const serviceAgreement = await upgrades.deployProxy(
    ServiceAgreement,
    [config.arbitrator, config.feeCollector],
    { kind: "uups" }
  );
  await serviceAgreement.waitForDeployment();

  const proxyAddr = await serviceAgreement.getAddress();
  const implAddr = await upgrades.erc1967.getImplementationAddress(proxyAddr);
  console.log(`Proxy:          ${proxyAddr}`);
  console.log(`Implementation: ${implAddr}`);

  // Templates are non-privileged owner actions and apply immediately.
  for (const tpl of config.templates ?? []) {
    console.log(`Creating template: ${tpl.name}`);
    await (
      await serviceAgreement.createTemplate(
        tpl.name,
        tpl.terms,
        tpl.recommendedDuration,
        tpl.recommendedMilestones
      )
    ).wait();
  }

  // Schedule arbitrator pool rotation (timelocked).
  if (config.arbitratorPool && config.arbitratorPool.length > 0) {
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["address[]"], [config.arbitratorPool]);
    const tx = await serviceAgreement.scheduleAction(
      await serviceAgreement.ACTION_SET_ARBITRATOR_POOL(),
      data
    );
    const receipt = await tx.wait();
    const log = receipt.logs
      .map((l) => {
        try { return serviceAgreement.interface.parseLog(l); } catch { return null; }
      })
      .find((p) => p && p.name === "ActionScheduled");
    console.log(`Scheduled arbitrator pool update (actionId=${log.args.actionId}, executableAt=${log.args.executableAt})`);
  }

  // Schedule token whitelisting (timelocked).
  for (const token of config.whitelistedTokens ?? []) {
    const data = ethers.AbiCoder.defaultAbiCoder().encode(["address"], [token]);
    const tx = await serviceAgreement.scheduleAction(
      await serviceAgreement.ACTION_WHITELIST_TOKEN(),
      data
    );
    const receipt = await tx.wait();
    const log = receipt.logs
      .map((l) => {
        try { return serviceAgreement.interface.parseLog(l); } catch { return null; }
      })
      .find((p) => p && p.name === "ActionScheduled");
    console.log(`Scheduled whitelist for ${token} (actionId=${log.args.actionId}, executableAt=${log.args.executableAt})`);
  }

  console.log("Deployment complete. Run executeAction(actionId) for each scheduled action after the timelock elapses.");
  return { proxy: proxyAddr, implementation: implAddr };
}

function getNetworkConfig(networkName) {
  const oneDay = 24 * 60 * 60;
  const oneWeek = 7 * oneDay;
  const oneMonth = 30 * oneDay;

  const defaultTemplates = [
    {
      name: "Basic Agreement",
      terms: "Standard terms for a simple service agreement.",
      recommendedDuration: oneMonth,
      recommendedMilestones: 3,
    },
    {
      name: "Website Development",
      terms: "Terms for website development project.",
      recommendedDuration: 2 * oneMonth,
      recommendedMilestones: 5,
    },
    {
      name: "Smart Contract Audit",
      terms: "Terms for a smart contract security audit.",
      recommendedDuration: 3 * oneWeek,
      recommendedMilestones: 2,
    },
  ];

  const configs = {
    hardhat: {
      arbitrator: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      feeCollector: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
      arbitratorPool: [
        "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
        "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
      ],
      templates: defaultTemplates,
      whitelistedTokens: [],
    },
    sepolia: {
      arbitrator: process.env.ARBITRATOR ?? "",
      feeCollector: process.env.FEE_COLLECTOR ?? "",
      arbitratorPool: (process.env.ARBITRATOR_POOL ?? "").split(",").filter(Boolean),
      templates: defaultTemplates,
      whitelistedTokens: (process.env.WHITELIST_TOKENS ?? "").split(",").filter(Boolean),
    },
    mainnet: {
      arbitrator: process.env.ARBITRATOR ?? "",
      feeCollector: process.env.FEE_COLLECTOR ?? "",
      arbitratorPool: (process.env.ARBITRATOR_POOL ?? "").split(",").filter(Boolean),
      templates: defaultTemplates,
      whitelistedTokens: (process.env.WHITELIST_TOKENS ?? "").split(",").filter(Boolean),
    },
  };

  const cfg = configs[networkName] || configs.hardhat;
  if (!cfg.arbitrator || !cfg.feeCollector) {
    throw new Error(
      `Set ARBITRATOR and FEE_COLLECTOR env vars before deploying to ${networkName}`
    );
  }
  return cfg;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
