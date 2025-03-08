const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
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
    const oneDay = 24 * 60 * 60;
    const oneWeek = 7 * oneDay;
    const oneMonth = 30 * oneDay;

    beforeEach(async function () {
        // Get signers
        [owner, arbitrator, feeCollector, client, provider, ...addrs] = await ethers.getSigners();

        // Deploy mock ERC20 token
        const MockToken = await ethers.getContractFactory("MockERC20");
        mockToken = await MockToken.deploy("MockToken", "MTK", ethers.parseEther("10000"));

        // Deploy ServiceAgreement contract
        const ServiceAgreement = await ethers.getContractFactory("ServiceAgreement");
        serviceAgreement = await upgrades.deployProxy(ServiceAgreement, [
            arbitrator.address,
            feeCollector.address
        ]);

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
              .to.emit(serviceAgreement, "MilestoneCompleted");

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
              .deploy("New Token", "NEW", ethers.parseEther("10000"));

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
              .deploy("Bad Token", "BAD", ethers.parseEther("10000"));

          await expect(
              serviceAgreement.connect(client).createAgreementFromTemplate(
                  0,
                  provider.address,
                  [Math.floor(Date.now() / 1000) + 86400],
                  [ethers.parseEther("1")],
                  await newToken.getAddress()
              )
          ).to.be.revertedWithCustomError(serviceAgreement, "TokenNotWhitelisted");
      });

      it("Should fail when non-arbitrator tries to resolve dispute", async function () {
          // Create agreement and raise dispute
          await serviceAgreement.connect(client).createAgreementFromTemplate(
              0,
              provider.address,
              [Math.floor(Date.now() / 1000) + 86400],
              [ethers.parseEther("1")],
              ZERO_ADDRESS,
              { value: ethers.parseEther("1") }
          );
          
          await serviceAgreement.connect(client).raiseDispute(0, "Dispute reason");
          
          // Try to resolve dispute as non-arbitrator
          await expect(
              serviceAgreement.connect(client).resolveDispute(0, client.address, [])
          ).to.be.revertedWithCustomError(serviceAgreement, "OnlyArbitratorAllowed");
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
                .withArgs(1, templateName);

            const template = await serviceAgreement.templates(1);
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
            await mockToken.transfer(await serviceAgreement.getAddress(), amount);

            const contractBalanceBefore = await mockToken.balanceOf(await serviceAgreement.getAddress());
            const ownerBalanceBefore = await mockToken.balanceOf(owner.address);
            
            await serviceAgreement.connect(owner).emergencyWithdraw(tokenAddress);
            
            const contractBalanceAfter = await mockToken.balanceOf(await serviceAgreement.getAddress());
            const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
            
            expect(contractBalanceAfter).to.equal(0);
            expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(contractBalanceBefore);
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

    describe("Batch Operations", function () {
        let agreementId;
        const milestoneDueDates = [
            Math.floor(Date.now() / 1000) + 86400,
            Math.floor(Date.now() / 1000) + 172800,
            Math.floor(Date.now() / 1000) + 259200
        ];
        const milestoneAmounts = [
            ethers.parseEther("0.3"),
            ethers.parseEther("0.3"),
            ethers.parseEther("0.4")
        ];
        const totalAmount = ethers.parseEther("1");
        
        beforeEach(async function () {
            // Create test agreement
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                milestoneDueDates,
                milestoneAmounts,
                ZERO_ADDRESS,
                { value: totalAmount }
            );
            agreementId = 0;
            
            // Submit evidence for all milestones
            const evidenceHash = "QmTestEvidenceHash";
            for (let i = 0; i < 3; i++) {
                await serviceAgreement.connect(provider).submitMilestoneEvidence(
                    agreementId, i, evidenceHash
                );
            }
            
            // Complete all milestones
            for (let i = 0; i < 3; i++) {
                await serviceAgreement.connect(client).completeMilestone(
                    agreementId, i
                );
            }
        });
        
        it("Should batch release milestone payments", async function () {
            const providerBalanceBefore = await ethers.provider.getBalance(provider.address);
            const feeCollectorBalanceBefore = await ethers.provider.getBalance(feeCollector.address);
            
            // Release payments for milestones 0 and 1
            await serviceAgreement.connect(client).batchReleaseMilestonePayments(
                agreementId, [0, 1]
            );
            
            // Check milestone states
            const milestone0 = await serviceAgreement.getMilestoneDetails(agreementId, 0);
            const milestone1 = await serviceAgreement.getMilestoneDetails(agreementId, 1);
            const milestone2 = await serviceAgreement.getMilestoneDetails(agreementId, 2);
            
            expect(milestone0.paid).to.be.true;
            expect(milestone1.paid).to.be.true;
            expect(milestone2.paid).to.be.false;
            
            // Calculate expected payments
            const expectedPaymentAmount = ethers.parseEther("0.594"); // (0.3 + 0.3) * 0.99
            const expectedFeeAmount = ethers.parseEther("0.006"); // (0.3 + 0.3) * 0.01
            
            const providerBalanceAfter = await ethers.provider.getBalance(provider.address);
            const feeCollectorBalanceAfter = await ethers.provider.getBalance(feeCollector.address);
            
            // Check balances increased by expected amounts (approximately)
            const providerDiff = providerBalanceAfter - providerBalanceBefore;
            const feeDiff = feeCollectorBalanceAfter - feeCollectorBalanceBefore;
            
            expect(providerDiff).to.be.closeTo(expectedPaymentAmount, ethers.parseEther("0.001"));
            expect(feeDiff).to.be.closeTo(expectedFeeAmount, ethers.parseEther("0.001"));
            
            // Check agreement remaining amount
            const agreement = await serviceAgreement.getAgreementDetails(agreementId);
            expect(agreement.remainingAmount).to.equal(milestoneAmounts[2]);
        });
        
        it("Should handle batch operations with a single milestone", async function () {
            // Release payment for only milestone 2
            await serviceAgreement.connect(client).batchReleaseMilestonePayments(
                agreementId, [2]
            );
            
            const milestone2 = await serviceAgreement.getMilestoneDetails(agreementId, 2);
            expect(milestone2.paid).to.be.true;
            
            // Verify remaining amount
            const agreement = await serviceAgreement.getAgreementDetails(agreementId);
            expect(agreement.remainingAmount).to.equal(
                milestoneAmounts[0] + milestoneAmounts[1]
            );
        });
        
        it("Should revert when attempting to release unpaid milestone twice", async function () {
            // First release
            await serviceAgreement.connect(client).batchReleaseMilestonePayments(
                agreementId, [0]
            );
            
            // Second attempt should fail
            await expect(
                serviceAgreement.connect(client).batchReleaseMilestonePayments(
                    agreementId, [0]
                )
            ).to.be.revertedWithCustomError(serviceAgreement, "MilestoneAlreadyPaid");
        });
    });

    describe("Team Payment Distribution", function () {
        let agreementId;
        const teamMembers = [];
        const teamShares = [20, 30, 50]; // 20%, 30%, 50%
        const milestoneDueDates = [
            Math.floor(Date.now() / 1000) + 86400
        ];
        const milestoneAmounts = [
            ethers.parseEther("1")
        ];
        
        beforeEach(async function () {
            // Get team member addresses
            teamMembers[0] = addrs[0].address;
            teamMembers[1] = addrs[1].address;
            teamMembers[2] = addrs[2].address;
            
            // Create agreement
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                milestoneDueDates,
                milestoneAmounts,
                ZERO_ADDRESS,
                { value: ethers.parseEther("1") }
            );
            agreementId = 0;
            
            // Add team members
            await serviceAgreement.connect(provider).addTeamMembers(
                agreementId,
                teamMembers,
                teamShares
            );
            
            // Submit evidence and complete milestone
            await serviceAgreement.connect(provider).submitMilestoneEvidence(
                agreementId, 0, "QmTestHash"
            );
            await serviceAgreement.connect(client).completeMilestone(
                agreementId, 0
            );
        });
        
        it("Should distribute payments to team members according to shares", async function () {
            // Get balances before
            const balancesBefore = await Promise.all(
                teamMembers.map(addr => ethers.provider.getBalance(addr))
            );
            
            // Release payment
            await serviceAgreement.connect(client).releaseMilestonePayment(
                agreementId, 0
            );
            
            // Get balances after
            const balancesAfter = await Promise.all(
                teamMembers.map(addr => ethers.provider.getBalance(addr))
            );
            
            // Calculate differences
            const diffs = balancesAfter.map((after, i) => after - balancesBefore[i]);
            
            // Calculate expected payments
            const milestoneAmount = ethers.parseEther("1");
            const fee = milestoneAmount * BigInt(1) / BigInt(100);
            const netAmount = milestoneAmount - fee;
            
            const expectedPayments = teamShares.map(share => 
                (netAmount * BigInt(share)) / BigInt(100)
            );
            
            // Check that payments are close to expected values
            for (let i = 0; i < teamMembers.length; i++) {
                expect(diffs[i]).to.be.closeTo(expectedPayments[i], ethers.parseEther("0.0001"));
            }
        });
        
        it("Should revert when adding more than MAX_TEAM_MEMBERS", async function () {
            // Create new agreement
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                milestoneDueDates,
                milestoneAmounts,
                ZERO_ADDRESS,
                { value: ethers.parseEther("1") }
            );
            const newAgreementId = 1;
            
            // Create team with too many members
            const tooManyMembers = Array(11).fill().map((_, i) => addrs[i % addrs.length].address);
            const tooManyShares = Array(11).fill(909); // 11 * 909 ~= 10000
            
            await expect(
                serviceAgreement.connect(provider).addTeamMembers(
                    newAgreementId,
                    tooManyMembers,
                    tooManyShares
                )
            ).to.be.revertedWithCustomError(serviceAgreement, "TooManyTeamMembers");
        });
    });

    describe("Token Operations with Slippage Protection", function () {
        let mockTokenNoReturn;
        
        beforeEach(async function () {
            // Deploy a mock token that returns less than transferred (simulates fee on transfer)
            const MockTokenWithFee = await ethers.getContractFactory("MockTokenWithFee");
            mockTokenNoReturn = await MockTokenWithFee.deploy("Fee Token", "FEE", 100); // 1% fee
            
            // Mint tokens to client
            await mockTokenNoReturn.mint(client.address, ethers.parseEther("1000"));
            await mockTokenNoReturn.connect(client).approve(
                serviceAgreement.getAddress(), 
                ethers.parseEther("1000")
            );
            
            // Add token to whitelist but with timelock
            await serviceAgreement.addWhitelistedToken(await mockTokenNoReturn.getAddress());
            
            // Wait for timelock to pass
            await ethers.provider.send("evm_increaseTime", [3 * 24 * 60 * 60]); // 3 days
            await ethers.provider.send("evm_mine");
            
            // Execute the whitelisting action
            const actionId = ethers.keccak256(
                ethers.solidityPacked(
                    ["bytes32", "bytes", "uint256"],
                    [
                        await serviceAgreement.ACTION_WHITELIST_TOKEN(),
                        ethers.AbiCoder.defaultAbiCoder().encode(
                            ["address"], 
                            [await mockTokenNoReturn.getAddress()]
                        ),
                        (await ethers.provider.getBlock("latest")).timestamp - 3 * 24 * 60 * 60
                    ]
                )
            );
            await serviceAgreement.executeAction(actionId);
        });
        
        it("Should handle tokens with transfer fees when slippage is within limits", async function () {
            // Set token specific slippage to 1.5%
            await serviceAgreement.setTokenSlippage(await mockTokenNoReturn.getAddress(), 150);
            
            // Wait for timelock
            await ethers.provider.send("evm_increaseTime", [3 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            // Execute the slippage setting action
            const actionId = ethers.keccak256(
                ethers.solidityPacked(
                    ["bytes32", "bytes", "uint256"],
                    [
                        await serviceAgreement.ACTION_SET_TOKEN_SLIPPAGE(),
                        ethers.AbiCoder.defaultAbiCoder().encode(
                            ["address", "uint256"], 
                            [await mockTokenNoReturn.getAddress(), 150]
                        ),
                        (await ethers.provider.getBlock("latest")).timestamp - 3 * 24 * 60 * 60
                    ]
                )
            );
            await serviceAgreement.executeAction(actionId);
            
            // Create agreement with fee token
            const milestoneDueDates = [Math.floor(Date.now() / 1000) + 86400];
            const milestoneAmounts = [ethers.parseEther("100")];
            
            // This should work because 1% fee is within 1.5% slippage
            await serviceAgreement.connect(client).createAgreementFromTemplate(
                0,
                provider.address,
                milestoneDueDates,
                milestoneAmounts,
                await mockTokenNoReturn.getAddress()
            );
            
            // Verify agreement was created
            const agreement = await serviceAgreement.getAgreementDetails(0);
            expect(agreement.client).to.equal(client.address);
            expect(agreement.paymentToken).to.equal(await mockTokenNoReturn.getAddress());
        });
        
        it("Should reject transactions with excessive slippage", async function () {
            // Set token specific slippage to 0.5% (less than the token's 1% fee)
            await serviceAgreement.setTokenSlippage(await mockTokenNoReturn.getAddress(), 50);
            
            // Wait for timelock
            await ethers.provider.send("evm_increaseTime", [3 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            // Execute the slippage setting action
            const actionId = ethers.keccak256(
                ethers.solidityPacked(
                    ["bytes32", "bytes", "uint256"],
                    [
                        await serviceAgreement.ACTION_SET_TOKEN_SLIPPAGE(),
                        ethers.AbiCoder.defaultAbiCoder().encode(
                            ["address", "uint256"], 
                            [await mockTokenNoReturn.getAddress(), 50]
                        ),
                        (await ethers.provider.getBlock("latest")).timestamp - 3 * 24 * 60 * 60
                    ]
                )
            );
            await serviceAgreement.executeAction(actionId);
            
            // Create agreement with fee token
            const milestoneDueDates = [Math.floor(Date.now() / 1000) + 86400];
            const milestoneAmounts = [ethers.parseEther("100")];
            
            // This should fail because 1% fee exceeds 0.5% slippage
            await expect(
                serviceAgreement.connect(client).createAgreementFromTemplate(
                    0,
                    provider.address,
                    milestoneDueDates,
                    milestoneAmounts,
                    await mockTokenNoReturn.getAddress()
                )
            ).to.be.revertedWithCustomError(serviceAgreement, "SlippageExceeded");
        });
    });
});