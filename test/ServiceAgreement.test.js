const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("ServiceAgreement", function () {
    let serviceAgreement;
    let mockToken;
    let owner;
    let arbitrator;
    let feeCollector;
    let client;
    let provider;
    let addrs;

    const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

    beforeEach(async function () {
        // Get signers
        [owner, arbitrator, feeCollector, client, provider, ...addrs] = await ethers.getSigners();

        // Deploy mock ERC20 token
        const MockToken = await ethers.getContractFactory("MockERC20");
        mockToken = await MockToken.deploy("MockToken", "MTK");

        // Deploy ServiceAgreement contract
        const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement");
        serviceAgreement = await ServiceAgreement.deploy(
            arbitrator.address,
            feeCollector.address
        );

        // Add token to whitelist
        await serviceAgreement.addWhitelistedToken(await mockToken.getAddress());

        // Mint tokens to client
        const mintAmount = ethers.parseEther("1000");
        await mockToken.mint(client.address, mintAmount);
        await mockToken.connect(client).approve(serviceAgreement.getAddress(), mintAmount);
    });

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            expect(await serviceAgreement.owner()).to.equal(owner.address);
        });

        it("Should set the right arbitrator", async function () {
            expect(await serviceAgreement.arbitrator()).to.equal(arbitrator.address);
        });

        it("Should set the right fee collector", async function () {
            expect(await serviceAgreement.feeCollector()).to.equal(feeCollector.address);
        });
    });

    describe("Agreement Creation", function () {
        const milestoneDueDates = [
            Math.floor(Date.now() / 1000) + 86400, // 1 day from now
            Math.floor(Date.now() / 1000) + 172800 // 2 days from now
        ];
        const milestoneAmounts = [
            ethers.parseEther("0.5"),
            ethers.parseEther("0.5")
        ];
        const totalAmount = ethers.parseEther("1");
        const terms = "Test agreement terms";

        it("Should create agreement with ETH payment", async function () {
            const tx = await serviceAgreement.connect(client).createAgreementFromTemplate(
                0, // templateId
                provider.address,
                milestoneDueDates,
                milestoneAmounts,
                ZERO_ADDRESS, // ETH payment
                { value: totalAmount }
            );

            await expect(tx)
                .to.emit(serviceAgreement, "AgreementCreated")
                .withArgs(
                    0, // agreementId
                    client.address,
                    provider.address,
                    totalAmount,
                    2, // number of milestones
                    ZERO_ADDRESS,
                    terms
                );

            const agreement = await serviceAgreement.getAgreementDetails(0);
            expect(agreement.client).to.equal(client.address);
            expect(agreement.provider).to.equal(provider.address);
            expect(agreement.totalAmount).to.equal(totalAmount);
        });

        it("Should create agreement with ERC20 token payment", async function () {
            const tokenAddress = await mockToken.getAddress();
            
            const tx = await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                milestoneDueDates,
                milestoneAmounts,
                tokenAddress,
                { value: 0 }
            );

            await expect(tx)
                .to.emit(serviceAgreement, "AgreementCreated")
                .withArgs(
                    0,
                    client.address,
                    provider.address,
                    totalAmount,
                    2,
                    tokenAddress,
                    terms
                );
        });
    });
  
    describe("Milestone Management", function () {
      let agreementId;
      const milestoneDueDates = [
          Math.floor(Date.now() / 1000) + 86400,
          Math.floor(Date.now() / 1000) + 172800
      ];
      const milestoneAmounts = [
          ethers.parseEther("0.5"),
          ethers.parseEther("0.5")
      ];
      const totalAmount = ethers.parseEther("1");

      beforeEach(async function () {
          // Create a test agreement
          await serviceAgreement.connect(client).createAgreementFromTemplate(
              0,
              provider.address,
              milestoneDueDates,
              milestoneAmounts,
              ZERO_ADDRESS,
              { value: totalAmount }
          );
          agreementId = 0;
      });

      it("Should submit milestone evidence", async function () {
          const evidenceHash = "QmTest123";
          await expect(
              serviceAgreement.connect(provider).submitMilestoneEvidence(
                  agreementId,
                  0,
                  evidenceHash
              )
          )
              .to.emit(serviceAgreement, "MilestoneEvidenceSubmitted")
              .withArgs(agreementId, 0, evidenceHash);

          const milestone = await serviceAgreement.getMilestoneDetails(agreementId, 0);
          expect(milestone.evidenceHash).to.equal(evidenceHash);
      });

      it("Should complete milestone", async function () {
          const evidenceHash = "QmTest123";
          await serviceAgreement.connect(provider).submitMilestoneEvidence(
              agreementId,
              0,
              evidenceHash
          );

          await expect(
              serviceAgreement.connect(client).completeMilestone(agreementId, 0)
          )
              .to.emit(serviceAgreement, "MilestoneCompleted")
              .withArgs(agreementId, 0, await time.latest());

          const milestone = await serviceAgreement.getMilestoneDetails(agreementId, 0);
          expect(milestone.completed).to.be.true;
      });

      it("Should release milestone payment", async function () {
          // Submit and complete milestone first
          await serviceAgreement.connect(provider).submitMilestoneEvidence(
              agreementId,
              0,
              "QmTest123"
          );
          await serviceAgreement.connect(client).completeMilestone(agreementId, 0);

          const providerBalanceBefore = await ethers.provider.getBalance(provider.address);
          const feeCollectorBalanceBefore = await ethers.provider.getBalance(feeCollector.address);

          await expect(
              serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0)
          )
              .to.emit(serviceAgreement, "PaymentReleased");

          const milestone = await serviceAgreement.getMilestoneDetails(agreementId, 0);
          expect(milestone.paid).to.be.true;

          const providerBalanceAfter = await ethers.provider.getBalance(provider.address);
          const feeCollectorBalanceAfter = await ethers.provider.getBalance(feeCollector.address);

          // Check balances increased (exact amounts calculated based on fees)
          expect(providerBalanceAfter).to.be.gt(providerBalanceBefore);
          expect(feeCollectorBalanceAfter).to.be.gt(feeCollectorBalanceBefore);
      });
  });

  describe("Dispute Resolution", function () {
      let agreementId;

      beforeEach(async function () {
          // Create test agreement
          await serviceAgreement.connect(client).createAgreementFromTemplate(
              0,
              provider.address,
              [Math.floor(Date.now() / 1000) + 86400],
              [ethers.parseEther("1")],
              ZERO_ADDRESS,
              { value: ethers.parseEther("1") }
          );
          agreementId = 0;
      });

      it("Should raise dispute", async function () {
          const reason = "Work not completed as agreed";
          await expect(
              serviceAgreement.connect(client).raiseDispute(agreementId, reason)
          )
              .to.emit(serviceAgreement, "DisputeRaised")
              .withArgs(agreementId, client.address, reason);

          const agreement = await serviceAgreement.getAgreementDetails(agreementId);
          expect(agreement.disputed).to.be.true;
      });

      it("Should resolve dispute", async function () {
          await serviceAgreement.connect(client).raiseDispute(agreementId, "Test reason");

          const payouts = [ethers.parseEther("0.5")]; // 50% payout
          await expect(
              serviceAgreement.connect(arbitrator).resolveDispute(
                  agreementId,
                  provider.address,
                  payouts
              )
          )
              .to.emit(serviceAgreement, "DisputeResolved")
              .withArgs(agreementId, provider.address);

          const agreement = await serviceAgreement.getAgreementDetails(agreementId);
          expect(agreement.disputed).to.be.false;
          expect(agreement.completed).to.be.true;
      });
  });

  describe("Rating System", function () {
      let agreementId;

      beforeEach(async function () {
          // Create and complete an agreement
          await serviceAgreement.connect(client).createAgreementFromTemplate(
              0,
              provider.address,
              [Math.floor(Date.now() / 1000) + 86400],
              [ethers.parseEther("1")],
              ZERO_ADDRESS,
              { value: ethers.parseEther("1") }
          );
          agreementId = 0;

          // Complete the agreement
          await serviceAgreement.connect(provider).submitMilestoneEvidence(
              agreementId,
              0,
              "QmTest123"
          );
          await serviceAgreement.connect(client).completeMilestone(agreementId, 0);
          await serviceAgreement.connect(client).releaseMilestonePayment(agreementId, 0);
      });

      it("Should submit rating", async function () {
          const rating = 5;
          await expect(
              serviceAgreement.connect(client).submitRating(
                  agreementId,
                  provider.address,
                  rating
              )
          )
              .to.emit(serviceAgreement, "RatingSubmitted")
              .withArgs(agreementId, client.address, provider.address, rating);

          const providerRating = await serviceAgreement.getUserRating(provider.address);
          expect(providerRating.count).to.equal(1);
          expect(providerRating.total).to.equal(rating);
      });
  });

  describe("Token Management", function () {
      it("Should whitelist token", async function () {
          const newToken = await (await ethers.getContractFactory("MockERC20"))
              .deploy("New Token", "NEW");

          await expect(
              serviceAgreement.connect(owner).addWhitelistedToken(await newToken.getAddress())
          )
              .to.emit(serviceAgreement, "TokenWhitelisted")
              .withArgs(await newToken.getAddress(), true);

          expect(
              await serviceAgreement.whitelistedTokens(await newToken.getAddress())
          ).to.be.true;
      });

      it("Should remove token from whitelist", async function () {
          const tokenAddress = await mockToken.getAddress();
          await expect(
              serviceAgreement.connect(owner).removeWhitelistedToken(tokenAddress)
          )
              .to.emit(serviceAgreement, "TokenWhitelisted")
              .withArgs(tokenAddress, false);

          expect(await serviceAgreement.whitelistedTokens(tokenAddress)).to.be.false;
      });
  });

  describe("Edge Cases and Error Conditions", function () {
      it("Should fail when creating agreement with non-whitelisted token", async function () {
          const newToken = await (await ethers.getContractFactory("MockERC20"))
              .deploy("Bad Token", "BAD");

          await expect(
              serviceAgreement.connect(client).createAgreementFromTemplate(
                  0,
                  provider.address,
                  [Math.floor(Date.now() / 1000) + 86400],
                  [ethers.parseEther("1")],
                  await newToken.getAddress()
              )
          ).to.be.revertedWith("Token not whitelisted");
      });

      it("Should fail when non-arbitrator tries to resolve dispute", async function () {
          // Create and dispute an agreement first
          await serviceAgreement.connect(client).createAgreementFromTemplate(
              0,
              provider.address,
              [Math.floor(Date.now() / 1000) + 86400],
              [ethers.parseEther("1")],
              ZERO_ADDRESS,
              { value: ethers.parseEther("1") }
          );
          await serviceAgreement.connect(client).raiseDispute(0, "Test reason");

          await expect(
              serviceAgreement.connect(addrs[0]).resolveDispute(
                  0,
                  provider.address,
                  [ethers.parseEther("1")]
              )
          ).to.be.revertedWith("Only arbitrator can perform this action");
      });
  });

  describe("Template Management", function () {
        const templateName = "Basic Agreement";
        const templateTerms = "Standard terms for basic service agreement";
        const recommendedDuration = 30 * 24 * 60 * 60; // 30 days
        const recommendedMilestones = 3;

        it("Should create template", async function () {
            await expect(
                serviceAgreement.connect(owner).createTemplate(
                    templateName,
                    templateTerms,
                    recommendedDuration,
                    recommendedMilestones
                )
            )
                .to.emit(serviceAgreement, "TemplateCreated")
                .withArgs(0, templateName);

            const template = await serviceAgreement.templates(0);
            expect(template.name).to.equal(templateName);
            expect(template.terms).to.equal(templateTerms);
            expect(template.recommendedDuration).to.equal(recommendedDuration);
            expect(template.recommendedMilestones).to.equal(recommendedMilestones);
            expect(template.active).to.be.true;
        });

        it("Should update template", async function () {
            // Create template first
            await serviceAgreement.connect(owner).createTemplate(
                templateName,
                templateTerms,
                recommendedDuration,
                recommendedMilestones
            );

            const newName = "Updated Template";
            const newTerms = "Updated terms";
            
            await expect(
                serviceAgreement.connect(owner).updateTemplate(
                    0,
                    newName,
                    newTerms,
                    recommendedDuration,
                    recommendedMilestones,
                    true
                )
            )
                .to.emit(serviceAgreement, "TemplateUpdated")
                .withArgs(0, newName, true);

            const template = await serviceAgreement.templates(0);
            expect(template.name).to.equal(newName);
            expect(template.terms).to.equal(newTerms);
        });
    });

    describe("Emergency Functions", function () {
        it("Should allow emergency withdrawal of ETH", async function () {
            // Send some ETH to contract first
            await owner.sendTransaction({
                to: serviceAgreement.getAddress(),
                value: ethers.parseEther("1")
            });

            const balanceBefore = await ethers.provider.getBalance(owner.address);
            await serviceAgreement.connect(owner).emergencyWithdraw(ZERO_ADDRESS);
            const balanceAfter = await ethers.provider.getBalance(owner.address);

            expect(balanceAfter).to.be.gt(balanceBefore);
            expect(
                await ethers.provider.getBalance(serviceAgreement.getAddress())
            ).to.equal(0);
        });

        it("Should allow emergency withdrawal of tokens", async function () {
            const tokenAddress = await mockToken.getAddress();
            const amount = ethers.parseEther("100");

            // Send tokens to contract first
            await mockToken.transfer(serviceAgreement.getAddress(), amount);

            await expect(
                serviceAgreement.connect(owner).emergencyWithdraw(tokenAddress)
            ).to.changeTokenBalances(
                mockToken,
                [serviceAgreement.getAddress(), owner.address],
                [-amount, amount]
            );
        });
    });

    describe("Milestone Deadline Management", function () {
        let agreementId;

        beforeEach(async function () {
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                [Math.floor(Date.now() / 1000) + 86400],
                [ethers.parseEther("1")],
                ZERO_ADDRESS,
                { value: ethers.parseEther("1") }
            );
            agreementId = 0;
        });

        it("Should extend milestone deadline", async function () {
            const newDeadline = Math.floor(Date.now() / 1000) + (2 * 86400); // 2 days from now

            await expect(
                serviceAgreement.connect(client).extendMilestoneDeadline(
                    agreementId,
                    0,
                    newDeadline
                )
            )
                .to.emit(serviceAgreement, "MilestoneDeadlineExtended")
                .withArgs(agreementId, 0, newDeadline);

            const milestone = await serviceAgreement.getMilestoneDetails(agreementId, 0);
            expect(milestone.deadline).to.equal(newDeadline);
        });
    });

    describe("Agreement Cancellation", function () {
        let agreementId;

        beforeEach(async function () {
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                [Math.floor(Date.now() / 1000) + 86400],
                [ethers.parseEther("1")],
                ZERO_ADDRESS,
                { value: ethers.parseEther("1") }
            );
            agreementId = 0;
        });

        it("Should allow client to cancel agreement within timeframe", async function () {
            const reason = "Project requirements changed";
            
            await expect(
                serviceAgreement.connect(client).cancelAgreement(agreementId, reason)
            )
                .to.emit(serviceAgreement, "AgreementCancelled")
                .withArgs(agreementId, client.address, reason);

            const agreement = await serviceAgreement.getAgreementDetails(agreementId);
            expect(agreement.cancelled).to.be.true;
        });

        it("Should refund remaining amount on cancellation", async function () {
            const clientBalanceBefore = await ethers.provider.getBalance(client.address);

            await serviceAgreement.connect(client).cancelAgreement(
                agreementId,
                "Cancellation test"
            );

            const clientBalanceAfter = await ethers.provider.getBalance(client.address);
            expect(clientBalanceAfter).to.be.gt(clientBalanceBefore);
        });
    });

    describe("Batch View Functions", function () {
        let agreementId;
        const milestoneDueDates = [
            Math.floor(Date.now() / 1000) + 86400,
            Math.floor(Date.now() / 1000) + 172800
        ];
        const milestoneAmounts = [
            ethers.parseEther("0.5"),
            ethers.parseEther("0.5")
        ];

        beforeEach(async function () {
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                milestoneDueDates,
                milestoneAmounts,
                ZERO_ADDRESS,
                { value: ethers.parseEther("1") }
            );
            agreementId = 0;
        });

        it("Should get all milestones in single call", async function () {
            const [
                deadlines,
                amounts,
                completedStates,
                paidStates,
                evidenceHashes
            ] = await serviceAgreement.getMilestones(agreementId);

            expect(deadlines.length).to.equal(2);
            expect(amounts.length).to.equal(2);
            expect(completedStates.length).to.equal(2);
            expect(paidStates.length).to.equal(2);
            expect(evidenceHashes.length).to.equal(2);

            expect(deadlines[0]).to.equal(milestoneDueDates[0]);
            expect(amounts[0]).to.equal(milestoneAmounts[0]);
        });

        it("Should get user agreements", async function () {
            const clientAgreements = await serviceAgreement.getUserAgreements(client.address);
            const providerAgreements = await serviceAgreement.getUserAgreements(provider.address);

            expect(clientAgreements.length).to.equal(1);
            expect(providerAgreements.length).to.equal(1);
            expect(clientAgreements[0]).to.equal(agreementId);
            expect(providerAgreements[0]).to.equal(agreementId);
        });
    });
  
    describe("Template Management", function () {
        const templateName = "Basic Agreement";
        const templateTerms = "Standard terms for basic service agreement";
        const recommendedDuration = 30 * 24 * 60 * 60; // 30 days
        const recommendedMilestones = 3;

        it("Should create template", async function () {
            await expect(
                serviceAgreement.connect(owner).createTemplate(
                    templateName,
                    templateTerms,
                    recommendedDuration,
                    recommendedMilestones
                )
            )
                .to.emit(serviceAgreement, "TemplateCreated")
                .withArgs(0, templateName);

            const template = await serviceAgreement.templates(0);
            expect(template.name).to.equal(templateName);
            expect(template.terms).to.equal(templateTerms);
            expect(template.recommendedDuration).to.equal(recommendedDuration);
            expect(template.recommendedMilestones).to.equal(recommendedMilestones);
            expect(template.active).to.be.true;
        });

        it("Should update template", async function () {
            // Create template first
            await serviceAgreement.connect(owner).createTemplate(
                templateName,
                templateTerms,
                recommendedDuration,
                recommendedMilestones
            );

            const newName = "Updated Template";
            const newTerms = "Updated terms";
            
            await expect(
                serviceAgreement.connect(owner).updateTemplate(
                    0,
                    newName,
                    newTerms,
                    recommendedDuration,
                    recommendedMilestones,
                    true
                )
            )
                .to.emit(serviceAgreement, "TemplateUpdated")
                .withArgs(0, newName, true);

            const template = await serviceAgreement.templates(0);
            expect(template.name).to.equal(newName);
            expect(template.terms).to.equal(newTerms);
        });
    });

    describe("Emergency Functions", function () {
        it("Should allow emergency withdrawal of ETH", async function () {
            // Send some ETH to contract first
            await owner.sendTransaction({
                to: serviceAgreement.getAddress(),
                value: ethers.parseEther("1")
            });

            const balanceBefore = await ethers.provider.getBalance(owner.address);
            await serviceAgreement.connect(owner).emergencyWithdraw(ZERO_ADDRESS);
            const balanceAfter = await ethers.provider.getBalance(owner.address);

            expect(balanceAfter).to.be.gt(balanceBefore);
            expect(
                await ethers.provider.getBalance(serviceAgreement.getAddress())
            ).to.equal(0);
        });

        it("Should allow emergency withdrawal of tokens", async function () {
            const tokenAddress = await mockToken.getAddress();
            const amount = ethers.parseEther("100");

            // Send tokens to contract first
            await mockToken.transfer(serviceAgreement.getAddress(), amount);

            await expect(
                serviceAgreement.connect(owner).emergencyWithdraw(tokenAddress)
            ).to.changeTokenBalances(
                mockToken,
                [serviceAgreement.getAddress(), owner.address],
                [-amount, amount]
            );
        });
    });

    describe("Milestone Deadline Management", function () {
        let agreementId;

        beforeEach(async function () {
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                [Math.floor(Date.now() / 1000) + 86400],
                [ethers.parseEther("1")],
                ZERO_ADDRESS,
                { value: ethers.parseEther("1") }
            );
            agreementId = 0;
        });

        it("Should extend milestone deadline", async function () {
            const newDeadline = Math.floor(Date.now() / 1000) + (2 * 86400); // 2 days from now

            await expect(
                serviceAgreement.connect(client).extendMilestoneDeadline(
                    agreementId,
                    0,
                    newDeadline
                )
            )
                .to.emit(serviceAgreement, "MilestoneDeadlineExtended")
                .withArgs(agreementId, 0, newDeadline);

            const milestone = await serviceAgreement.getMilestoneDetails(agreementId, 0);
            expect(milestone.deadline).to.equal(newDeadline);
        });
    });

    describe("Agreement Cancellation", function () {
        let agreementId;

        beforeEach(async function () {
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                [Math.floor(Date.now() / 1000) + 86400],
                [ethers.parseEther("1")],
                ZERO_ADDRESS,
                { value: ethers.parseEther("1") }
            );
            agreementId = 0;
        });

        it("Should allow client to cancel agreement within timeframe", async function () {
            const reason = "Project requirements changed";
            
            await expect(
                serviceAgreement.connect(client).cancelAgreement(agreementId, reason)
            )
                .to.emit(serviceAgreement, "AgreementCancelled")
                .withArgs(agreementId, client.address, reason);

            const agreement = await serviceAgreement.getAgreementDetails(agreementId);
            expect(agreement.cancelled).to.be.true;
        });

        it("Should refund remaining amount on cancellation", async function () {
            const clientBalanceBefore = await ethers.provider.getBalance(client.address);

            await serviceAgreement.connect(client).cancelAgreement(
                agreementId,
                "Cancellation test"
            );

            const clientBalanceAfter = await ethers.provider.getBalance(client.address);
            expect(clientBalanceAfter).to.be.gt(clientBalanceBefore);
        });
    });

    describe("Batch View Functions", function () {
        let agreementId;
        const milestoneDueDates = [
            Math.floor(Date.now() / 1000) + 86400,
            Math.floor(Date.now() / 1000) + 172800
        ];
        const milestoneAmounts = [
            ethers.parseEther("0.5"),
            ethers.parseEther("0.5")
        ];

        beforeEach(async function () {
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                milestoneDueDates,
                milestoneAmounts,
                ZERO_ADDRESS,
                { value: ethers.parseEther("1") }
            );
            agreementId = 0;
        });

        it("Should get all milestones in single call", async function () {
            const [
                deadlines,
                amounts,
                completedStates,
                paidStates,
                evidenceHashes
            ] = await serviceAgreement.getMilestones(agreementId);

            expect(deadlines.length).to.equal(2);
            expect(amounts.length).to.equal(2);
            expect(completedStates.length).to.equal(2);
            expect(paidStates.length).to.equal(2);
            expect(evidenceHashes.length).to.equal(2);

            expect(deadlines[0]).to.equal(milestoneDueDates[0]);
            expect(amounts[0]).to.equal(milestoneAmounts[0]);
        });

        it("Should get user agreements", async function () {
            const clientAgreements = await serviceAgreement.getUserAgreements(client.address);
            const providerAgreements = await serviceAgreement.getUserAgreements(provider.address);

            expect(clientAgreements.length).to.equal(1);
            expect(providerAgreements.length).to.equal(1);
            expect(clientAgreements[0]).to.equal(agreementId);
            expect(providerAgreements[0]).to.equal(agreementId);
        });
    });
});