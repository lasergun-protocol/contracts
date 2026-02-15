# Anonymous Shield Smart Contracts

## Overview

Anonymous Shield is a privacy-preserving smart contract system that enables anonymous transfers and storage of ERC20 tokens on Ethereum and compatible networks. The system uses commitment-based cryptography to hide balances and transaction details while maintaining full functionality.

## Features

- **Privacy-First**: Balances and transaction details are hidden using cryptographic commitments
- **Anonymous Transfers**: Send tokens to recipients without revealing sender identity
- **Auto-Consolidation**: Maintain single active Shield per user for optimal UX
- **Gas Optimized**: Efficient operations with minimal gas costs
- **Secure**: Multi-role access control and emergency pause functionality
- **Upgradeable**: UUPS proxy pattern for future improvements
- **Fee System**: Configurable fees for shield/unshield operations
- **Escrow Support**: Two-phase confirmation mechanism for enhanced security

## Escrow Mechanism

The LaserGun contract includes an escrow mechanism that provides an additional layer of security for token transfers. This feature allows senders to create escrow shields that require explicit confirmation before funds can be released to recipients.

### Key Features

- **Two-Phase Confirmation**: Sender creates escrow and must confirm before release
- **Time-Bound Confirmation**: Configurable confirmation periods (1 hour to 30 days)
- **Cancellation Option**: Senders can cancel unconfirmed escrows or after deadline expiration
- **Privacy Preservation**: All escrow operations maintain the same privacy guarantees as regular shields

### Escrow Workflow

1. **Create Escrow**: Sender creates an escrow shield with recipient and confirmation period
2. **Confirm Escrow**: Sender explicitly confirms the transaction within the deadline
3. **Release Funds**: After confirmation, sender releases funds to recipient using the secret

For detailed documentation, see [Escrow Mechanism Documentation](./docs/escrow-mechanism.md) and [Escrow Usage Example](./examples/escrow-example.js).

## Architecture

### Core Components

1. **Shields**: Commitment-based token storage with hidden balances
2. **Shield/Unshield**: Convert between public and private tokens
3. **Transfers**: Anonymous peer-to-peer token transfers
4. **Consolidation**: Merge multiple Shields into one

### Privacy Model

```
Public Tokens → Shield → Private Shield → Transfer → Private Shield → Unshield → Public Tokens
     ↑                      ↓                           ↓                         ↑
  Visible             Hidden Balance              Hidden Balance           Visible
```

## Quick Start

### Prerequisites

- Node.js >= 16.0.0
- npm or yarn

### Installation

```bash
# Clone repository
git clone https://github.com/lasergun-protocol/contracts
cd anonymous-Shield-contracts

# Install dependencies
npm install

# Copy environment variables
cp .env.example .env
# Edit .env with your configuration

# Compile contracts
npm run compile
```

### Testing

```bash
# Run all tests
npm test

# Run tests with gas reporting
npm run test:gas

# Run coverage
npm run test:coverage
```

### Deployment

```bash
# Deploy to local network
npm run node  # In separate terminal
npm run deploy:localhost

# Deploy to testnet
npm run deploy:amoy

# Deploy to mainnet
npm run deploy:polygon

# Deploy to Avalanche
npm run deploy:avalanche
```

### Contract Verification

#### Automatic Verification (Recommended)

```bash
# Deploy with automatic verification
npm run deploy:auto:amoy      # Amoy testnet
npm run deploy:auto:polygon   # Polygon mainnet
npm run deploy:auto:avalanche # Avalanche mainnet
```

#### Manual Verification

```bash
# Verify after deployment
npm run verify:amoy           # Amoy testnet
npm run verify:polygon        # Polygon mainnet
npm run verify:avalanche      # Avalanche mainnet

# Manual verification with specific address
npm run verify:manual:amoy <implementation_address>
npm run verify:manual:polygon <implementation_address>
npm run verify:manual:avalanche <implementation_address>
```

#### Verification Requirements

To verify contracts, you need to add the following API keys to your `.env` file:

```bash
# For Polygon/Amoy verification
POLYGONSCAN_API_KEY=your_polygonscan_api_key_here

# For Avalanche verification
SNOWTRACE_API_KEY=your_snowtrace_api_key_here

# Enable automatic verification after deployment
AUTO_VERIFY=true
```

## Contract API

### Core Functions

#### `deposit(uint256 amount, address token, bytes32 commitment)`
Convert public tokens to private Shield (Shield operation)

#### `redeem(bytes32 secret, uint256 redeemAmount, bytes32 newCommitment)`
Convert private Shield to public tokens (Unshield operation)

#### `createShieldForRecipient(bytes32 secret, uint256 amount, address recipient, bytes32 recipientCommitment)`
Transfer portion of Shield to another user

#### `consolidate(bytes32[] secrets, bytes32 newCommitment)`
Merge multiple Shields into single Shield

### Escrow Functions

#### `createEscrowShield(uint256 amount, address token, bytes32 commitment, address recipient, uint256 confirmationPeriod, bytes32 bloomFilter)`
Create an escrow shield with confirmation requirement

#### `confirmEscrow(bytes32 commitment)`
Confirm an escrow shield by the sender

#### `releaseEscrow(bytes32 commitment, bytes32 secret)`
Release confirmed escrow funds to recipient

#### `cancelEscrow(bytes32 commitment, bytes32 secret)`
Cancel an escrow and return funds to sender

### View Functions

#### `getShieldInfo(bytes32 commitment) → (bool exists, address token, uint256 amount, uint256 timestamp, bool spent)`
Get Shield details

#### `getShieldBalance(bytes32 secret, address token) → uint256`
Check Shield balance for specific secret

#### `generateCommitment(bytes32 secret, address recipient) → bytes32`
Generate commitment hash

## Security Features

### Access Control
- **ADMIN_ROLE**: System administration
- **FEE_MANAGER_ROLE**: Fee configuration
- **PAUSER_ROLE**: Emergency pause/unpause
- **UPGRADER_ROLE**: Contract upgrades

### Emergency Functions
- **Pause/Unpause**: Stop all operations in emergency
- **Emergency Withdraw**: Admin can only withdraw collected fees
- **Upgrade Protection**: Multi-role authorization required

### Audit Status
- Internal security review completed
- External audit pending
- Bug bounty program planned

## Gas Costs

| Operation | Estimated Gas | Notes |
|-----------|---------------|-------|
| Deposit | ~150,000 | First-time deposit |
| Redeem | ~120,000 | Full amount |
| Transfer | ~180,000 | Including remainder |
| Consolidate (2) | ~170,000 | Two Shields |
| Consolidate (10) | ~400,000 | Maximum Shields |
| Create Escrow | ~180,000-230,000 | With confirmation period |
| Confirm Escrow | ~50,000-70,000 | Sender confirmation |
| Release Escrow | ~80,000-100,000 | After confirmation |
| Cancel Escrow | ~80,000-100,000 | Return to sender |

## Testing

### Test Categories

- **Unit Tests**: Individual function testing
- **Integration Tests**: Cross-function workflows  
- **Gas Tests**: Gas optimization verification
- **Security Tests**: Attack vector prevention
- **Upgrade Tests**: Proxy upgrade compatibility

### Running Specific Tests

```bash
# Unit tests only
npm test -- --grep "Unit"

# Gas optimization tests
npm test -- --grep "Gas"

# Security tests
npm test -- --grep "Security"
```

## Contract Verification

### Polygon Mainnet
- **Proxy**: `0x...` ([View on PolygonScan](https://polygonscan.com/address/0x...)) )

### Amoy Testnet
- **Proxy**: `0x7a9046293dF17d2ec81eF4606376bFE1b45A2f18` ([View on PolygonScan](https://mumbai.polygonscan.com/address/0x7a9046293dF17d2ec81eF4606376bFE1b45A2f18)) 

## 🔧 Development

### Code Quality

```bash
# Lint Solidity code
npm run lint

# Fix linting issues
npm run lint:fix

# Format code
npm run prettier

# Security analysis
npm run security
```

### Project Structure

```
contracts/
├── LaserGun.sol     # Main contract
├── interfaces/              # Contract interfaces
├── libraries/               # Utility libraries
└── mocks/                   # Test contracts

scripts/
├── deploy.js               # Deployment script
├── upgrade.js              # Upgrade script
└── utils/                  # Helper functions

test/
├── LaserGun.test.js        # Core tests
└── LaserGun.escrow.test.js # Escrow-specific tests

docs/
└── escrow-mechanism.md     # Escrow mechanism documentation

examples/
└── escrow-example.js       # Escrow usage examples
```

## Security Considerations

### Known Limitations
- Frontend must track user commitments locally
- Requires external secret sharing for transfers  
- Gas costs increase with number of Shields to consolidate

### Best Practices
- Always use strong randomness for secrets
- Implement proper secret sharing mechanisms
- Monitor for unusual gas usage patterns
- Keep emergency procedures documented

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open Pull Request

### Development Guidelines
- Write comprehensive tests for new features
- Follow existing code style and patterns
- Update documentation for API changes
- Ensure all tests pass before submitting

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

 

## Disclaimer

This software is provided "as is" without warranty. Use at your own risk. Always conduct thorough testing before deploying to mainnet.