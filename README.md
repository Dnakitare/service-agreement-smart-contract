# Service Agreement Smart Contract

A comprehensive decentralized service agreement platform built on Ethereum that enables secure, milestone-based service agreements between clients and service providers.

## Features

- **Milestone-based Agreements**: Create and manage service agreements with granular milestone management
- **Multi-token Support**: Accept payments in ETH or any whitelisted ERC20 token
- **Team Collaboration**: Distribute payments among multiple team members with custom share allocation
- **Advanced Dispute Resolution**: Multi-level arbitration system with escalation
- **Partial Completion**: Support for partial milestone completion and proportional payments
- **Slippage Protection**: Built-in protection against fee-on-transfer tokens
- **Timelock Security**: Critical admin actions require timelock delays
- **Upgradeable Design**: UUPS proxy pattern for future upgrades
- **Rating System**: Reputation system weighted by transaction values

## Contract Architecture

The ServiceAgreement contract uses the UUPS (Universal Upgradeable Proxy Standard) pattern for upgradeability, allowing for future enhancements while preserving state and contract address.

### Core Components

- **Agreement**: Central data structure for service agreements containing all agreement details
- **Milestone**: Deliverable with deadline, payment amount, and completion evidence
- **Template**: Reusable agreement templates for standard service types
- **Rating**: User reputation system with transaction-weighted scores
- **Batch Operations**: Gas-efficient methods for processing multiple milestones
- **Team Payments**: Distribute payments among team members by percentage

### Security Features

- **Reentrancy Protection**: Guards against reentrancy attacks
- **Access Control**: Role-based access control for all sensitive functions
- **Timelock**: Mandatory delay for critical admin functions
- **Slippage Protection**: Protection against token transfer fees or deductions
- **Validation**: Comprehensive input validation with custom errors

## Development

### Prerequisites

- Node.js v16+
- npm or yarn
- Hardhat

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/service-agreement.git
cd service-agreement

# Install dependencies
npm install
```

### Testing

```bash
# Run tests
npx hardhat test

# Run coverage
npx hardhat coverage
```

### Deployment

```bash
# Deploy to local hardhat network
npx hardhat run scripts/deploy.js

# Deploy to testnet
npx hardhat run scripts/deploy.js --network sepolia

# Upgrade an existing contract
PROXY_ADDRESS=0xYourProxyAddress npx hardhat run scripts/upgrade.js --network sepolia

# Verify contract on Etherscan
IMPLEMENTATION_ADDRESS=0xYourImplementationAddress npx hardhat run scripts/verify.js --network sepolia
```

## Usage Guide

### Creating an Agreement

1. **Select a Template**: Choose from pre-defined agreement templates
2. **Define Milestones**: Set up milestones with deadlines and payment amounts
3. **Fund the Agreement**: Deposit ETH or approved ERC20 tokens
4. **Add Team Members** (optional): Provider can add team members with payment shares
5. **Execute the Work**: Provider submits evidence of milestone completion
6. **Approve and Release Payments**: Client approves completion and releases payment

### Dispute Resolution Process

If there's a disagreement between client and provider:

1. **Raise a Dispute**: Either party can raise a dispute with evidence
2. **Arbitration**: Designated arbitrator reviews the evidence and resolves the dispute
3. **Escalation** (if needed): Dispute can be escalated to higher-level arbitrators
4. **Resolution**: Funds are distributed according to the arbitrator's decision

### Ratings and Reputation

After completing an agreement:
1. Client can rate the provider
2. Provider can rate the client
3. Ratings are weighted by transaction value
4. Ratings contribute to participants' overall reputation scores

## Administration

### Token Management

```bash
# Whitelist a token (by admin)
# Note: Subject to timelock delay
npx hardhat run scripts/whitelist-token.js --token 0xTokenAddress --network sepolia

# Set token slippage tolerance (by admin)
# Note: Subject to timelock delay
npx hardhat run scripts/set-token-slippage.js --token 0xTokenAddress --slippage 50 --network sepolia
```

### Arbitrator Management

```bash
# Set arbitrator pool (by admin)
npx hardhat run scripts/set-arbitrator-pool.js --arbitrators 0xAddr1,0xAddr2,0xAddr3 --network sepolia
```

## License

MIT
