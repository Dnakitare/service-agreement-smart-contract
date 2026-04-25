const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const ZERO = ethers.ZeroAddress;
const BPS = 10_000n;
const FEE_BPS = 100n; // matches PLATFORM_FEE_BPS in contract
const TIMELOCK = 2 * 24 * 60 * 60;
const CANCEL_WINDOW = 24 * 60 * 60;

// Helper: deterministic milestone schedule starting "now + offset" on the chain clock.
async function chainNow() {
  const block = await ethers.provider.getBlock("latest");
  return block.timestamp;
}

async function futureTimes(...offsets) {
  const t = await chainNow();
  return offsets.map((o) => t + o);
}

async function scheduleAndExecute(serviceAgreement, owner, actionType, encodedData) {
  const tx = await serviceAgreement.connect(owner).scheduleAction(actionType, encodedData);
  const receipt = await tx.wait();
  const log = receipt.logs
    .map((l) => {
      try {
        return serviceAgreement.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((p) => p && p.name === "ActionScheduled");
  const actionId = log.args.actionId;
  await time.increase(TIMELOCK + 1);
  await serviceAgreement.connect(owner).executeAction(actionId);
  return actionId;
}

describe("ServiceAgreement", function () {
  let serviceAgreement;
  let mockToken;
  let owner, arbitrator, feeCollector, client, provider, otherArb, addrs;

  beforeEach(async () => {
    [owner, arbitrator, feeCollector, client, provider, otherArb, ...addrs] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("MockERC20");
    mockToken = await MockToken.deploy("MockToken", "MTK", ethers.parseEther("0"));

    const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement");
    serviceAgreement = await upgrades.deployProxy(
      ServiceAgreement,
      [arbitrator.address, feeCollector.address],
      { kind: "uups" }
    );

    // Whitelist the mock token via the timelock.
    await scheduleAndExecute(
      serviceAgreement,
      owner,
      await serviceAgreement.ACTION_WHITELIST_TOKEN(),
      ethers.AbiCoder.defaultAbiCoder().encode(["address"], [await mockToken.getAddress()])
    );

    // Seed a default template (ID 0) since the contract no longer auto-creates one.
    await serviceAgreement.connect(owner).createTemplate(
      "Default Template",
      "Test agreement terms",
      30 * 24 * 60 * 60,
      2
    );

    // Fund the client with mock tokens and approve the contract.
    await mockToken.mint(client.address, ethers.parseEther("1000"));
    await mockToken.connect(client).approve(serviceAgreement.getAddress(), ethers.MaxUint256);
  });

  // ----------------------------------------------------------------------------
  // Deployment
  // ----------------------------------------------------------------------------

  describe("Deployment", () => {
    it("sets owner, fee collector, and seeds the arbitrator pool", async () => {
      expect(await serviceAgreement.owner()).to.equal(owner.address);
      expect(await serviceAgreement.feeCollector()).to.equal(feeCollector.address);
      expect(await serviceAgreement.isArbitrator(arbitrator.address)).to.be.true;
      expect(await serviceAgreement.arbitratorCount()).to.equal(1);
    });

    it("rejects zero addresses on init", async () => {
      const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement");
      await expect(
        upgrades.deployProxy(ServiceAgreement, [ZERO, feeCollector.address], { kind: "uups" })
      ).to.be.revertedWithCustomError(ServiceAgreement, "ZeroAddress");
    });
  });

  // ----------------------------------------------------------------------------
  // Timelock
  // ----------------------------------------------------------------------------

  describe("Timelock", () => {
    it("does not apply the change immediately when scheduled", async () => {
      const newToken = await (await ethers.getContractFactory("MockERC20")).deploy("X", "X", 0);
      const data = ethers.AbiCoder.defaultAbiCoder().encode(["address"], [await newToken.getAddress()]);
      await serviceAgreement.connect(owner).scheduleAction(
        await serviceAgreement.ACTION_WHITELIST_TOKEN(),
        data
      );
      // Still NOT whitelisted until execution.
      expect(await serviceAgreement.whitelistedTokens(await newToken.getAddress())).to.be.false;
    });

    it("rejects execution before the delay elapses", async () => {
      const newToken = await (await ethers.getContractFactory("MockERC20")).deploy("X", "X", 0);
      const data = ethers.AbiCoder.defaultAbiCoder().encode(["address"], [await newToken.getAddress()]);
      const tx = await serviceAgreement.connect(owner).scheduleAction(
        await serviceAgreement.ACTION_WHITELIST_TOKEN(),
        data
      );
      const receipt = await tx.wait();
      const actionId = receipt.logs
        .map((l) => {
          try { return serviceAgreement.interface.parseLog(l); } catch { return null; }
        })
        .find((p) => p && p.name === "ActionScheduled").args.actionId;

      await time.increase(TIMELOCK - 60);
      await expect(serviceAgreement.connect(owner).executeAction(actionId))
        .to.be.revertedWithCustomError(serviceAgreement, "TimelockNotElapsed");
    });

    it("rejects unknown action types", async () => {
      const bogus = ethers.keccak256(ethers.toUtf8Bytes("BOGUS"));
      await expect(
        serviceAgreement.connect(owner).scheduleAction(bogus, "0x")
      ).to.be.revertedWithCustomError(serviceAgreement, "InvalidActionType");
    });

    it("can cancel a scheduled action", async () => {
      const newToken = await (await ethers.getContractFactory("MockERC20")).deploy("X", "X", 0);
      const data = ethers.AbiCoder.defaultAbiCoder().encode(["address"], [await newToken.getAddress()]);
      const tx = await serviceAgreement.connect(owner).scheduleAction(
        await serviceAgreement.ACTION_WHITELIST_TOKEN(),
        data
      );
      const receipt = await tx.wait();
      const actionId = receipt.logs
        .map((l) => { try { return serviceAgreement.interface.parseLog(l); } catch { return null; } })
        .find((p) => p && p.name === "ActionScheduled").args.actionId;
      await serviceAgreement.connect(owner).cancelScheduledAction(actionId);
      await time.increase(TIMELOCK + 60);
      await expect(serviceAgreement.connect(owner).executeAction(actionId))
        .to.be.revertedWithCustomError(serviceAgreement, "ActionNotFound");
    });

    it("non-owner cannot schedule", async () => {
      await expect(
        serviceAgreement.connect(client).scheduleAction(
          await serviceAgreement.ACTION_SET_FEE_COLLECTOR(),
          ethers.AbiCoder.defaultAbiCoder().encode(["address"], [client.address])
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "OwnableUnauthorizedAccount");
    });

    it("rotates the arbitrator pool through the timelock", async () => {
      const newPool = [otherArb.address, addrs[0].address];
      await scheduleAndExecute(
        serviceAgreement,
        owner,
        await serviceAgreement.ACTION_SET_ARBITRATOR_POOL(),
        ethers.AbiCoder.defaultAbiCoder().encode(["address[]"], [newPool])
      );
      expect(await serviceAgreement.isArbitrator(arbitrator.address)).to.be.false;
      expect(await serviceAgreement.isArbitrator(otherArb.address)).to.be.true;
      expect(await serviceAgreement.isArbitrator(addrs[0].address)).to.be.true;
    });
  });

  // ----------------------------------------------------------------------------
  // Agreement creation
  // ----------------------------------------------------------------------------

  describe("Agreement Creation", () => {
    it("creates an ETH-funded agreement and updates obligations", async () => {
      const dueDates = await futureTimes(86400, 172800);
      const amounts = [ethers.parseEther("0.5"), ethers.parseEther("0.5")];
      const total = ethers.parseEther("1");

      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, amounts, ZERO, { value: total }
        )
      )
        .to.emit(serviceAgreement, "AgreementCreated")
        .withArgs(0, client.address, provider.address, total, 2, ZERO, "Test agreement terms");

      expect(await serviceAgreement.totalObligations(ZERO)).to.equal(total);

      const a = await serviceAgreement.getAgreementDetails(0);
      expect(a.client).to.equal(client.address);
      expect(a.totalAmount).to.equal(total);
      expect(a.remainingAmount).to.equal(total);
    });

    it("creates an ERC20-funded agreement and pulls the exact amount", async () => {
      const dueDates = await futureTimes(86400, 172800);
      const amounts = [ethers.parseEther("0.5"), ethers.parseEther("0.5")];
      const total = ethers.parseEther("1");
      const tokenAddr = await mockToken.getAddress();

      const before = await mockToken.balanceOf(client.address);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, amounts, tokenAddr
      );
      const after = await mockToken.balanceOf(client.address);
      expect(before - after).to.equal(total);
      expect(await serviceAgreement.totalObligations(tokenAddr)).to.equal(total);
    });

    it("rejects ETH sent with a token-funded agreement", async () => {
      const dueDates = await futureTimes(86400);
      const amounts = [ethers.parseEther("1")];
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, amounts, await mockToken.getAddress(),
          { value: 1n }
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "EthNotAcceptedForToken");
    });

    it("rejects mismatched ETH amount", async () => {
      const dueDates = await futureTimes(86400);
      const amounts = [ethers.parseEther("1")];
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, amounts, ZERO, { value: ethers.parseEther("0.9") }
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "WrongPaymentAmount");
    });

    it("rejects non-chronological milestones", async () => {
      const t = await chainNow();
      const dueDates = [t + 172800, t + 86400];
      const amounts = [ethers.parseEther("0.5"), ethers.parseEther("0.5")];
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, amounts, ZERO, { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "MilestonesNotChronological");
    });

    it("rejects past first milestone", async () => {
      const t = await chainNow();
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, [t - 1], [ethers.parseEther("1")], ZERO,
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "InvalidDeadline");
    });

    it("rejects deadlines beyond MAX_DEADLINE", async () => {
      const t = await chainNow();
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, [t + 366 * 86400], [ethers.parseEther("1")], ZERO,
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "DurationTooLong");
    });

    it("rejects provider == client", async () => {
      const dueDates = await futureTimes(86400);
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, client.address, dueDates, [ethers.parseEther("1")], ZERO,
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "InvalidProvider");
    });

    it("rejects non-whitelisted tokens", async () => {
      const stranger = await (await ethers.getContractFactory("MockERC20")).deploy("X", "X", 0);
      const dueDates = await futureTimes(86400);
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, [ethers.parseEther("1")], await stranger.getAddress()
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "TokenNotWhitelisted");
    });

    it("supports the no-template create path", async () => {
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreement(
        provider.address, "Custom terms", dueDates, [ethers.parseEther("1")], ZERO,
        { value: ethers.parseEther("1") }
      );
      const a = await serviceAgreement.getAgreementDetails(0);
      expect(a.terms).to.equal("Custom terms");
    });
  });

  // ----------------------------------------------------------------------------
  // Milestone lifecycle
  // ----------------------------------------------------------------------------

  describe("Milestone lifecycle", () => {
    let agreementId;

    beforeEach(async () => {
      const dueDates = await futureTimes(86400, 172800);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates,
        [ethers.parseEther("0.5"), ethers.parseEther("0.5")],
        ZERO, { value: ethers.parseEther("1") }
      );
      agreementId = 0;
    });

    it("submits evidence, completes, and credits the provider via pull", async () => {
      await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "QmA");
      await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0);

      const amount = ethers.parseEther("0.5");
      const fee = (amount * FEE_BPS) / BPS;
      const net = amount - fee;
      expect(await serviceAgreement.pendingWithdrawals(ZERO, provider.address)).to.equal(net);
      expect(await serviceAgreement.pendingWithdrawals(ZERO, feeCollector.address)).to.equal(fee);
    });

    it("requires evidence before completion", async () => {
      await expect(
        serviceAgreement.connect(client).completeMilestone(agreementId, 0)
      ).to.be.revertedWithCustomError(serviceAgreement, "EvidenceMissing");
    });

    it("rejects empty evidence", async () => {
      await expect(
        serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "")
      ).to.be.revertedWithCustomError(serviceAgreement, "EvidenceEmpty");
    });

    it("rejects re-completion", async () => {
      await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "QmA");
      await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
      await expect(
        serviceAgreement.connect(client).completeMilestone(agreementId, 0)
      ).to.be.revertedWithCustomError(serviceAgreement, "MilestoneAlreadyCompleted");
    });

    it("rejects payment for un-completed milestones", async () => {
      await expect(
        serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0)
      ).to.be.revertedWithCustomError(serviceAgreement, "MilestoneNotCompleted");
    });

    it("marks the agreement complete when the final milestone is paid", async () => {
      for (const i of [0, 1]) {
        await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, i, `Q${i}`);
        await serviceAgreement.connect(client).completeMilestone(agreementId, i);
        await serviceAgreement.connect(client).releaseMilestonePayment(agreementId, i);
      }
      const a = await serviceAgreement.getAgreementDetails(agreementId);
      expect(a.completed).to.be.true;
    });

    it("blocks payment release while disputed", async () => {
      await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
      await serviceAgreement.connect(client).raiseDispute(agreementId, "x");
      await expect(
        serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0)
      ).to.be.revertedWithCustomError(serviceAgreement, "AgreementClosed");
    });

    it("extends a milestone deadline", async () => {
      const t = await chainNow();
      const newDeadline = t + 5 * 86400;
      await expect(
        serviceAgreement.connect(client).extendMilestoneDeadline(agreementId, 0, newDeadline)
      )
        .to.emit(serviceAgreement, "MilestoneDeadlineExtended")
        .withArgs(agreementId, 0, newDeadline);
    });

    it("rejects extending to an earlier deadline", async () => {
      await expect(
        serviceAgreement.connect(client).extendMilestoneDeadline(agreementId, 0, 1)
      ).to.be.revertedWithCustomError(serviceAgreement, "InvalidDeadline");
    });
  });

  // ----------------------------------------------------------------------------
  // Batch payments
  // ----------------------------------------------------------------------------

  describe("Batch payments", () => {
    let agreementId;
    const amounts = [ethers.parseEther("0.3"), ethers.parseEther("0.3"), ethers.parseEther("0.4")];

    beforeEach(async () => {
      const dueDates = await futureTimes(86400, 172800, 259200);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, amounts, ZERO, { value: ethers.parseEther("1") }
      );
      agreementId = 0;
      for (let i = 0; i < 3; i++) {
        await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, i, `Q${i}`);
        await serviceAgreement.connect(client).completeMilestone(agreementId, i);
      }
    });

    it("credits provider and fee collector for batched releases", async () => {
      await serviceAgreement.connect(client).batchReleaseMilestonePayments(agreementId, [0, 1]);
      const total = amounts[0] + amounts[1];
      const fee = (total * FEE_BPS) / BPS;
      const net = total - fee;
      expect(await serviceAgreement.pendingWithdrawals(ZERO, provider.address)).to.equal(net);
      expect(await serviceAgreement.pendingWithdrawals(ZERO, feeCollector.address)).to.equal(fee);
    });

    it("rejects double-release in a batch", async () => {
      await serviceAgreement.connect(client).batchReleaseMilestonePayments(agreementId, [0]);
      await expect(
        serviceAgreement.connect(client).batchReleaseMilestonePayments(agreementId, [0])
      ).to.be.revertedWithCustomError(serviceAgreement, "MilestoneAlreadyPaid");
    });

    it("rejects empty batch", async () => {
      await expect(
        serviceAgreement.connect(client).batchReleaseMilestonePayments(agreementId, [])
      ).to.be.revertedWithCustomError(serviceAgreement, "InvalidArrayLength");
    });
  });

  // ----------------------------------------------------------------------------
  // Cancellation
  // ----------------------------------------------------------------------------

  describe("Cancellation", () => {
    let agreementId;

    beforeEach(async () => {
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
        { value: ethers.parseEther("1") }
      );
      agreementId = 0;
    });

    it("client cancels within window and is credited the full amount", async () => {
      await serviceAgreement.connect(client).cancelAgreement(agreementId, "changed mind");
      expect(await serviceAgreement.pendingWithdrawals(ZERO, client.address)).to.equal(ethers.parseEther("1"));
      const a = await serviceAgreement.getAgreementDetails(agreementId);
      expect(a.cancelled).to.be.true;
      expect(a.remainingAmount).to.equal(0);
    });

    it("rejects cancellation after the window", async () => {
      await time.increase(CANCEL_WINDOW + 60);
      await expect(
        serviceAgreement.connect(client).cancelAgreement(agreementId, "late")
      ).to.be.revertedWithCustomError(serviceAgreement, "CancellationWindowExpired");
    });

    it("rejects cancellation if a milestone has been paid", async () => {
      await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0);
      await expect(
        serviceAgreement.connect(client).cancelAgreement(agreementId, "x")
      ).to.be.revertedWithCustomError(serviceAgreement, "AgreementClosed");
    });

    it("rejects cancellation while disputed", async () => {
      await serviceAgreement.connect(client).raiseDispute(agreementId, "x");
      await expect(
        serviceAgreement.connect(client).cancelAgreement(agreementId, "x")
      ).to.be.revertedWithCustomError(serviceAgreement, "AgreementClosed");
    });

    it("provider cannot cancel", async () => {
      await expect(
        serviceAgreement.connect(provider).cancelAgreement(agreementId, "x")
      ).to.be.revertedWithCustomError(serviceAgreement, "Unauthorized");
    });
  });

  // ----------------------------------------------------------------------------
  // Disputes
  // ----------------------------------------------------------------------------

  describe("Disputes", () => {
    let agreementId;
    const total = ethers.parseEther("1");

    beforeEach(async () => {
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [total], ZERO, { value: total }
      );
      agreementId = 0;
    });

    it("either party may raise; double-raise reverts", async () => {
      await serviceAgreement.connect(provider).raiseDispute(agreementId, "x");
      await expect(
        serviceAgreement.connect(client).raiseDispute(agreementId, "x")
      ).to.be.revertedWithCustomError(serviceAgreement, "DisputeAlreadyRaised");
    });

    it("non-arbitrator cannot resolve", async () => {
      await serviceAgreement.connect(client).raiseDispute(agreementId, "x");
      await expect(
        serviceAgreement.connect(client).resolveDispute(agreementId, total / 2n)
      ).to.be.revertedWithCustomError(serviceAgreement, "Unauthorized");
    });

    it("splits remaining amount between provider (with fee) and client", async () => {
      await serviceAgreement.connect(client).raiseDispute(agreementId, "x");
      const toProvider = ethers.parseEther("0.6");
      await serviceAgreement.connect(arbitrator).resolveDispute(agreementId, toProvider);

      const fee = (toProvider * FEE_BPS) / BPS;
      const net = toProvider - fee;
      const toClient = total - toProvider;

      expect(await serviceAgreement.pendingWithdrawals(ZERO, provider.address)).to.equal(net);
      expect(await serviceAgreement.pendingWithdrawals(ZERO, feeCollector.address)).to.equal(fee);
      expect(await serviceAgreement.pendingWithdrawals(ZERO, client.address)).to.equal(toClient);

      const a = await serviceAgreement.getAgreementDetails(agreementId);
      expect(a.completed).to.be.true;
      expect(a.disputed).to.be.false;
      expect(a.remainingAmount).to.equal(0);
    });

    it("rejects amountToProvider > remaining", async () => {
      await serviceAgreement.connect(client).raiseDispute(agreementId, "x");
      await expect(
        serviceAgreement.connect(arbitrator).resolveDispute(agreementId, total + 1n)
      ).to.be.revertedWithCustomError(serviceAgreement, "InsufficientFunds");
    });

    it("rejects resolving an undisputed agreement", async () => {
      await expect(
        serviceAgreement.connect(arbitrator).resolveDispute(agreementId, 0)
      ).to.be.revertedWithCustomError(serviceAgreement, "AgreementNotDisputed");
    });
  });

  // ----------------------------------------------------------------------------
  // Ratings
  // ----------------------------------------------------------------------------

  describe("Ratings", () => {
    let agreementId;
    const total = ethers.parseEther("1");

    beforeEach(async () => {
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [total], ZERO, { value: total }
      );
      agreementId = 0;
    });

    it("rejects rating before completion", async () => {
      await expect(
        serviceAgreement.connect(client).submitRating(agreementId, provider.address, 5)
      ).to.be.revertedWithCustomError(serviceAgreement, "AgreementNotComplete");
    });

    it("submits rating after completion", async () => {
      await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0);

      await serviceAgreement.connect(client).submitRating(agreementId, provider.address, 5);
      const r = await serviceAgreement.getUserRating(provider.address);
      expect(r.count).to.equal(1);
      expect(r.total).to.equal(5);
      expect(r.average).to.equal(5);
      expect(r.weightedAverage).to.equal(5);
    });

    it("rejects double rating from the same address", async () => {
      await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0);

      await serviceAgreement.connect(client).submitRating(agreementId, provider.address, 5);
      await expect(
        serviceAgreement.connect(client).submitRating(agreementId, provider.address, 4)
      ).to.be.revertedWithCustomError(serviceAgreement, "AlreadyRated");
    });

    it("rejects out-of-range scores", async () => {
      await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0);
      await expect(
        serviceAgreement.connect(client).submitRating(agreementId, provider.address, 0)
      ).to.be.revertedWithCustomError(serviceAgreement, "InvalidRating");
      await expect(
        serviceAgreement.connect(client).submitRating(agreementId, provider.address, 6)
      ).to.be.revertedWithCustomError(serviceAgreement, "InvalidRating");
    });

    it("rejects self-rating", async () => {
      await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0);
      await expect(
        serviceAgreement.connect(client).submitRating(agreementId, client.address, 5)
      ).to.be.revertedWithCustomError(serviceAgreement, "CannotRateSelf");
    });
  });

  // ----------------------------------------------------------------------------
  // Team payments
  // ----------------------------------------------------------------------------

  describe("Team payments", () => {
    let agreementId;
    const total = ethers.parseEther("1");

    beforeEach(async () => {
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [total], ZERO, { value: total }
      );
      agreementId = 0;
    });

    it("requires shares to sum to BASIS_POINTS", async () => {
      await expect(
        serviceAgreement.connect(provider).addTeamMembers(
          agreementId, [addrs[0].address, addrs[1].address], [5000, 4000]
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "InvalidShares");
    });

    it("rejects more than MAX_TEAM_MEMBERS", async () => {
      const members = Array(11).fill(0).map((_, i) => addrs[i].address);
      // Even with valid-summing shares, length should fail first.
      const shares = [...Array(10).fill(909), 910]; // sums to 10000, length 11
      await expect(
        serviceAgreement.connect(provider).addTeamMembers(agreementId, members, shares)
      ).to.be.revertedWithCustomError(serviceAgreement, "TooManyTeamMembers");
    });

    it("distributes by basis-point shares with rounding absorbed by last member", async () => {
      const members = [addrs[0].address, addrs[1].address, addrs[2].address];
      const shares = [2000, 3000, 5000]; // 20/30/50%
      await serviceAgreement.connect(provider).addTeamMembers(agreementId, members, shares);
      await serviceAgreement.connect(provider).submitMilestoneEvidence(agreementId, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0);

      const fee = (total * FEE_BPS) / BPS;
      const net = total - fee;
      const expectM0 = (net * 2000n) / 10000n;
      const expectM1 = (net * 3000n) / 10000n;
      const expectM2 = net - expectM0 - expectM1; // last absorbs dust

      expect(await serviceAgreement.pendingWithdrawals(ZERO, addrs[0].address)).to.equal(expectM0);
      expect(await serviceAgreement.pendingWithdrawals(ZERO, addrs[1].address)).to.equal(expectM1);
      expect(await serviceAgreement.pendingWithdrawals(ZERO, addrs[2].address)).to.equal(expectM2);
      // Provider receives nothing directly when team is set.
      expect(await serviceAgreement.pendingWithdrawals(ZERO, provider.address)).to.equal(0);
    });

    it("cannot reassign team after first paid milestone", async () => {
      // New 2-milestone agreement: pay #0 then try to add team with #1 still open.
      const dueDates = await futureTimes(86400, 172800);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates,
        [ethers.parseEther("0.5"), ethers.parseEther("0.5")],
        ZERO, { value: ethers.parseEther("1") }
      );
      const id = 1;
      await serviceAgreement.connect(provider).submitMilestoneEvidence(id, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(id, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(id, 0);
      await expect(
        serviceAgreement.connect(provider).addTeamMembers(
          id, [addrs[0].address], [10000]
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "TeamAlreadySet");
    });
  });

  // ----------------------------------------------------------------------------
  // Pull payments
  // ----------------------------------------------------------------------------

  describe("Pull payments", () => {
    it("provider claims credited ETH via withdraw", async () => {
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
        { value: ethers.parseEther("1") }
      );
      await serviceAgreement.connect(provider).submitMilestoneEvidence(0, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(0, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(0, 0);

      const fee = (ethers.parseEther("1") * FEE_BPS) / BPS;
      const net = ethers.parseEther("1") - fee;

      const before = await ethers.provider.getBalance(provider.address);
      const tx = await serviceAgreement.connect(provider).withdraw(ZERO);
      const receipt = await tx.wait();
      const gas = receipt.gasUsed * receipt.gasPrice;
      const after = await ethers.provider.getBalance(provider.address);

      expect(after - before + gas).to.equal(net);
      expect(await serviceAgreement.pendingWithdrawals(ZERO, provider.address)).to.equal(0);
    });

    it("rejects withdraw with zero balance", async () => {
      await expect(
        serviceAgreement.connect(addrs[5]).withdraw(ZERO)
      ).to.be.revertedWithCustomError(serviceAgreement, "NothingToWithdraw");
    });

    it("a refusing receiver does NOT block other recipients", async () => {
      // Deploy a contract that rejects ETH on receive.
      const Refuser = await ethers.getContractFactory("EthRefuser");
      const refuser = await Refuser.deploy();
      const refuserAddr = await refuser.getAddress();

      // Fund the refuser as one of the team members; provider sends from "provider" signer.
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
        { value: ethers.parseEther("1") }
      );
      await serviceAgreement.connect(provider).addTeamMembers(
        0, [refuserAddr, addrs[0].address], [5000, 5000]
      );
      await serviceAgreement.connect(provider).submitMilestoneEvidence(0, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(0, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(0, 0);

      // The honest team member can still withdraw despite the refuser.
      const before = await ethers.provider.getBalance(addrs[0].address);
      const tx = await serviceAgreement.connect(addrs[0]).withdraw(ZERO);
      const receipt = await tx.wait();
      const gas = receipt.gasUsed * receipt.gasPrice;
      const after = await ethers.provider.getBalance(addrs[0].address);

      const net = ethers.parseEther("1") - (ethers.parseEther("1") * FEE_BPS) / BPS;
      const expected = net / 2n;
      expect(after - before + gas).to.equal(expected);

      // Refuser's withdraw reverts but their balance remains claimable for someone else
      // routing if they ever could (here they cannot, but the key property is no DoS).
      await expect(refuser.tryWithdraw(serviceAgreement.getAddress()))
        .to.be.revertedWithCustomError(serviceAgreement, "TransferFailed");
    });
  });

  // ----------------------------------------------------------------------------
  // Surplus withdraw (replaces unsafe emergencyWithdraw)
  // ----------------------------------------------------------------------------

  describe("Surplus withdraw", () => {
    it("cannot drain escrowed user funds", async () => {
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
        { value: ethers.parseEther("1") }
      );
      await expect(
        serviceAgreement.connect(owner).withdrawSurplus(ZERO, owner.address)
      ).to.be.revertedWithCustomError(serviceAgreement, "NothingToWithdraw");
    });

    it("withdraws only the surplus from accidental transfers", async () => {
      // Create an agreement to set obligations.
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
        { value: ethers.parseEther("1") }
      );

      // Send surplus ETH directly to the contract.
      await owner.sendTransaction({ to: await serviceAgreement.getAddress(), value: ethers.parseEther("0.25") });

      const recipient = addrs[7].address;
      const before = await ethers.provider.getBalance(recipient);
      await serviceAgreement.connect(owner).withdrawSurplus(ZERO, recipient);
      const after = await ethers.provider.getBalance(recipient);
      expect(after - before).to.equal(ethers.parseEther("0.25"));

      // Escrow remains intact and the agreement is still claimable.
      expect(await serviceAgreement.totalObligations(ZERO)).to.equal(ethers.parseEther("1"));
    });
  });

  // ----------------------------------------------------------------------------
  // Fee-on-transfer rejection
  // ----------------------------------------------------------------------------

  describe("Fee-on-transfer rejection", () => {
    it("rejects deposit of a fee-on-transfer token", async () => {
      const FeeToken = await ethers.getContractFactory("MockTokenWithFee");
      const feeToken = await FeeToken.deploy("Fee", "FEE", 100);
      const addr = await feeToken.getAddress();

      // Whitelist via timelock.
      await scheduleAndExecute(
        serviceAgreement,
        owner,
        await serviceAgreement.ACTION_WHITELIST_TOKEN(),
        ethers.AbiCoder.defaultAbiCoder().encode(["address"], [addr])
      );

      await feeToken.mint(client.address, ethers.parseEther("100"));
      await feeToken.connect(client).approve(serviceAgreement.getAddress(), ethers.MaxUint256);

      const dueDates = await futureTimes(86400);
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, [ethers.parseEther("10")], addr
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "FeeOnTransferNotSupported");
    });
  });

  // ----------------------------------------------------------------------------
  // Templates
  // ----------------------------------------------------------------------------

  describe("Templates", () => {
    it("creates and updates a template", async () => {
      await serviceAgreement.connect(owner).createTemplate("X", "terms", 30 * 86400, 3);
      const id = (await serviceAgreement.templateCount()) - 1n;
      await serviceAgreement.connect(owner).updateTemplate(id, "Y", "terms2", 30 * 86400, 4, true);
      const t = await serviceAgreement.templates(id);
      expect(t.name).to.equal("Y");
      expect(t.terms).to.equal("terms2");
      expect(t.recommendedMilestones).to.equal(4);
    });

    it("inactive template rejects new agreements", async () => {
      await serviceAgreement.connect(owner).updateTemplate(0, "X", "terms", 30 * 86400, 2, false);
      const dueDates = await futureTimes(86400);
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "TemplateNotActive");
    });
  });

  // ----------------------------------------------------------------------------
  // Solvency invariant
  // ----------------------------------------------------------------------------

  describe("Solvency invariant", () => {
    it("ETH: contract balance >= totalObligations after each operation", async () => {
      const dueDates = await futureTimes(86400, 172800);
      const amounts = [ethers.parseEther("0.5"), ethers.parseEther("0.5")];
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, amounts, ZERO, { value: ethers.parseEther("1") }
      );

      const checkInvariant = async () => {
        const bal = await ethers.provider.getBalance(serviceAgreement.getAddress());
        const obligated = await serviceAgreement.totalObligations(ZERO);
        expect(bal).to.be.gte(obligated);
      };

      await checkInvariant();

      await serviceAgreement.connect(provider).submitMilestoneEvidence(0, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(0, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(0, 0);
      await checkInvariant();

      await serviceAgreement.connect(provider).withdraw(ZERO);
      await checkInvariant();

      await serviceAgreement.connect(feeCollector).withdraw(ZERO);
      await checkInvariant();

      await serviceAgreement.connect(provider).submitMilestoneEvidence(0, 1, "Q");
      await serviceAgreement.connect(client).completeMilestone(0, 1);
      await serviceAgreement.connect(client).releaseMilestonePayment(0, 1);
      await checkInvariant();

      await serviceAgreement.connect(provider).withdraw(ZERO);
      await serviceAgreement.connect(feeCollector).withdraw(ZERO);
      await checkInvariant();

      // After everyone withdraws, no obligations remain.
      expect(await serviceAgreement.totalObligations(ZERO)).to.equal(0);
    });

    it("ERC20: contract balance == totalObligations after deposits", async () => {
      const tokenAddr = await mockToken.getAddress();
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], tokenAddr
      );
      const bal = await mockToken.balanceOf(serviceAgreement.getAddress());
      const obligated = await serviceAgreement.totalObligations(tokenAddr);
      expect(bal).to.equal(obligated);
    });

    it("dispute resolution preserves the invariant", async () => {
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
        { value: ethers.parseEther("1") }
      );
      await serviceAgreement.connect(client).raiseDispute(0, "x");
      await serviceAgreement.connect(arbitrator).resolveDispute(0, ethers.parseEther("0.4"));

      const bal = await ethers.provider.getBalance(serviceAgreement.getAddress());
      const obligated = await serviceAgreement.totalObligations(ZERO);
      expect(bal).to.equal(obligated);
    });
  });

  // ----------------------------------------------------------------------------
  // Additional timelock paths
  // ----------------------------------------------------------------------------

  describe("Timelock: fee collector + token removal", () => {
    it("rotates the fee collector through the timelock", async () => {
      const newCollector = addrs[8].address;
      await scheduleAndExecute(
        serviceAgreement,
        owner,
        await serviceAgreement.ACTION_SET_FEE_COLLECTOR(),
        ethers.AbiCoder.defaultAbiCoder().encode(["address"], [newCollector])
      );
      expect(await serviceAgreement.feeCollector()).to.equal(newCollector);
    });

    it("rejects zero address as fee collector at execution time", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(["address"], [ZERO]);
      const tx = await serviceAgreement.connect(owner).scheduleAction(
        await serviceAgreement.ACTION_SET_FEE_COLLECTOR(),
        data
      );
      const receipt = await tx.wait();
      const actionId = receipt.logs
        .map((l) => { try { return serviceAgreement.interface.parseLog(l); } catch { return null; } })
        .find((p) => p && p.name === "ActionScheduled").args.actionId;
      await time.increase(TIMELOCK + 1);
      await expect(serviceAgreement.connect(owner).executeAction(actionId))
        .to.be.revertedWithCustomError(serviceAgreement, "ZeroAddress");
    });

    it("removes a token from the whitelist via timelock", async () => {
      const tokenAddr = await mockToken.getAddress();
      expect(await serviceAgreement.whitelistedTokens(tokenAddr)).to.be.true;

      await scheduleAndExecute(
        serviceAgreement,
        owner,
        await serviceAgreement.ACTION_REMOVE_TOKEN(),
        ethers.AbiCoder.defaultAbiCoder().encode(["address"], [tokenAddr])
      );
      expect(await serviceAgreement.whitelistedTokens(tokenAddr)).to.be.false;

      // New agreements using the now-removed token must fail.
      const dueDates = await futureTimes(86400);
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, [ethers.parseEther("1")], tokenAddr
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "TokenNotWhitelisted");
    });

    it("empty arbitrator pool reverts at execution time", async () => {
      const data = ethers.AbiCoder.defaultAbiCoder().encode(["address[]"], [[]]);
      const tx = await serviceAgreement.connect(owner).scheduleAction(
        await serviceAgreement.ACTION_SET_ARBITRATOR_POOL(),
        data
      );
      const receipt = await tx.wait();
      const actionId = receipt.logs
        .map((l) => { try { return serviceAgreement.interface.parseLog(l); } catch { return null; } })
        .find((p) => p && p.name === "ActionScheduled").args.actionId;
      await time.increase(TIMELOCK + 1);
      await expect(serviceAgreement.connect(owner).executeAction(actionId))
        .to.be.revertedWithCustomError(serviceAgreement, "InvalidArrayLength");
    });

    it("arbitrator pool dedupes repeated addresses", async () => {
      const pool = [otherArb.address, otherArb.address, addrs[0].address];
      await scheduleAndExecute(
        serviceAgreement,
        owner,
        await serviceAgreement.ACTION_SET_ARBITRATOR_POOL(),
        ethers.AbiCoder.defaultAbiCoder().encode(["address[]"], [pool])
      );
      expect(await serviceAgreement.arbitratorCount()).to.equal(2);
      expect(await serviceAgreement.isArbitrator(otherArb.address)).to.be.true;
      expect(await serviceAgreement.isArbitrator(addrs[0].address)).to.be.true;
    });

    it("rejects zero address inside arbitrator pool", async () => {
      const pool = [otherArb.address, ZERO];
      const data = ethers.AbiCoder.defaultAbiCoder().encode(["address[]"], [pool]);
      const tx = await serviceAgreement.connect(owner).scheduleAction(
        await serviceAgreement.ACTION_SET_ARBITRATOR_POOL(),
        data
      );
      const receipt = await tx.wait();
      const actionId = receipt.logs
        .map((l) => { try { return serviceAgreement.interface.parseLog(l); } catch { return null; } })
        .find((p) => p && p.name === "ActionScheduled").args.actionId;
      await time.increase(TIMELOCK + 1);
      await expect(serviceAgreement.connect(owner).executeAction(actionId))
        .to.be.revertedWithCustomError(serviceAgreement, "ZeroAddress");
    });
  });

  // ----------------------------------------------------------------------------
  // ERC20 pull payments and surplus
  // ----------------------------------------------------------------------------

  describe("ERC20 withdraw + surplus", () => {
    it("withdraws ERC20 credits", async () => {
      const tokenAddr = await mockToken.getAddress();
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], tokenAddr
      );
      await serviceAgreement.connect(provider).submitMilestoneEvidence(0, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(0, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(0, 0);

      const fee = (ethers.parseEther("1") * FEE_BPS) / BPS;
      const net = ethers.parseEther("1") - fee;

      const before = await mockToken.balanceOf(provider.address);
      await serviceAgreement.connect(provider).withdraw(tokenAddr);
      const after = await mockToken.balanceOf(provider.address);
      expect(after - before).to.equal(net);

      expect(await serviceAgreement.pendingWithdrawals(tokenAddr, provider.address)).to.equal(0);
    });

    it("surplus-withdraws accidentally-sent ERC20 tokens", async () => {
      const tokenAddr = await mockToken.getAddress();
      // Seed an agreement to create some obligations.
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], tokenAddr
      );

      // Transfer extra tokens directly to the contract (accidental).
      await mockToken.mint(owner.address, ethers.parseEther("5"));
      await mockToken.transfer(await serviceAgreement.getAddress(), ethers.parseEther("5"));

      const recipient = addrs[9].address;
      const before = await mockToken.balanceOf(recipient);
      await serviceAgreement.connect(owner).withdrawSurplus(tokenAddr, recipient);
      const after = await mockToken.balanceOf(recipient);
      expect(after - before).to.equal(ethers.parseEther("5"));
    });

    it("rejects zero-address recipient for surplus withdraw", async () => {
      await expect(
        serviceAgreement.connect(owner).withdrawSurplus(ZERO, ZERO)
      ).to.be.revertedWithCustomError(serviceAgreement, "ZeroAddress");
    });
  });

  // ----------------------------------------------------------------------------
  // Upgrade path
  // ----------------------------------------------------------------------------

  describe("Upgrade", () => {
    it("owner can upgrade the implementation", async () => {
      const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement");
      const before = await upgrades.erc1967.getImplementationAddress(await serviceAgreement.getAddress());
      await upgrades.upgradeProxy(await serviceAgreement.getAddress(), ServiceAgreement);
      const after = await upgrades.erc1967.getImplementationAddress(await serviceAgreement.getAddress());
      // State survives: arbitrator still seeded.
      expect(await serviceAgreement.isArbitrator(arbitrator.address)).to.be.true;
      // Implementation address may differ (new deployment) or match (idempotent) — either is fine.
      expect(typeof before).to.equal("string");
      expect(typeof after).to.equal("string");
    });

    it("non-owner cannot upgrade", async () => {
      const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement", client);
      await expect(
        upgrades.upgradeProxy(await serviceAgreement.getAddress(), ServiceAgreement)
      ).to.be.reverted;
    });
  });

  // ----------------------------------------------------------------------------
  // Views
  // ----------------------------------------------------------------------------

  describe("Views", () => {
    let agreementId;
    const amounts = [ethers.parseEther("0.4"), ethers.parseEther("0.6")];

    beforeEach(async () => {
      const dueDates = await futureTimes(86400, 172800);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, amounts, ZERO, { value: ethers.parseEther("1") }
      );
      agreementId = 0;
    });

    it("getMilestoneCount + getMilestone + getMilestones", async () => {
      expect(await serviceAgreement.getMilestoneCount(agreementId)).to.equal(2);

      const m0 = await serviceAgreement.getMilestone(agreementId, 0);
      expect(m0.amount).to.equal(amounts[0]);
      expect(m0.completed).to.be.false;

      const all = await serviceAgreement.getMilestones(agreementId);
      expect(all.length).to.equal(2);
      expect(all[1].amount).to.equal(amounts[1]);
    });

    it("getMilestone reverts on bad index", async () => {
      await expect(
        serviceAgreement.getMilestone(agreementId, 5)
      ).to.be.revertedWithCustomError(serviceAgreement, "MilestoneIndexOutOfBounds");
    });

    it("getTeam + getUserAgreements + hasRated", async () => {
      const [members, shares] = await serviceAgreement.getTeam(agreementId);
      expect(members.length).to.equal(0);
      expect(shares.length).to.equal(0);

      const userAgreements = await serviceAgreement.getUserAgreements(client.address);
      expect(userAgreements.map((n) => Number(n))).to.deep.equal([agreementId]);

      expect(await serviceAgreement.hasRated(agreementId, client.address)).to.be.false;
    });

    it("arbitratorPool view returns current pool", async () => {
      const pool = await serviceAgreement.arbitratorPool();
      expect(pool).to.deep.equal([arbitrator.address]);
    });
  });

  // ----------------------------------------------------------------------------
  // Pause
  // ----------------------------------------------------------------------------

  describe("Pause", () => {
    it("pauses creation but allows withdraw of already-credited funds", async () => {
      const dueDates = await futureTimes(86400);
      await serviceAgreement.connect(client).createAgreementFromTemplate(
        0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
        { value: ethers.parseEther("1") }
      );
      await serviceAgreement.connect(provider).submitMilestoneEvidence(0, 0, "Q");
      await serviceAgreement.connect(client).completeMilestone(0, 0);
      await serviceAgreement.connect(client).releaseMilestonePayment(0, 0);

      await serviceAgreement.connect(owner).pause();

      // New agreements blocked.
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(serviceAgreement, "EnforcedPause");

      // But pending withdrawals still work — funds remain claimable.
      await expect(serviceAgreement.connect(provider).withdraw(ZERO)).to.not.be.reverted;
    });

    it("owner can unpause", async () => {
      await serviceAgreement.connect(owner).pause();
      await serviceAgreement.connect(owner).unpause();
      const dueDates = await futureTimes(86400);
      await expect(
        serviceAgreement.connect(client).createAgreementFromTemplate(
          0, provider.address, dueDates, [ethers.parseEther("1")], ZERO,
          { value: ethers.parseEther("1") }
        )
      ).to.not.be.reverted;
    });
  });
});
