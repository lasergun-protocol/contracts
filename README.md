# Anonymous Voucher Smart Contracts

## Overview

Anonymous Voucher is a privacy-preserving smart contract system that enables anonymous transfers and storage of ERC20 tokens on Ethereum and compatible networks. The system uses commitment-based cryptography to hide balances and transaction details while maintaining full functionality.

## Features

- **Privacy-First**: Balances and transaction details are hidden using cryptographic commitments
- **Anonymous Transfers**: Send tokens to recipients without revealing sender identity
- **Auto-Consolidation**: Maintain single active voucher per user for optimal UX
- **Gas Optimized**: Efficient operations with minimal gas costs
- **Secure**: Multi-role access control and emergency pause functionality
- **Upgradeable**: UUPS proxy pattern for future improvements
- **Fee System**: Configurable fees for shield/unshield operations

## Architecture

### Core Components

1. **Vouchers**: Commitment-based token storage with hidden balances
2. **Shield/Unshield**: Convert between public and private tokens
3. **Transfers**: Anonymous peer-to-peer token transfers
4. **Consolidation**: Merge multiple vouchers into one

### Privacy Model

```
Public Tokens → Shield → Private Voucher → Transfer → Private Voucher → Unshield → Public Tokens
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
cd anonymous-voucher-contracts

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
npm run deploy:mumbai

# Deploy to mainnet
npm run deploy:polygon
```

## Contract API

### Core Functions

#### `deposit(uint256 amount, address token, bytes32 commitment)`
Convert public tokens to private voucher (Shield operation)

#### `redeem(bytes32 secret, uint256 redeemAmount, bytes32 newCommitment)`
Convert private voucher to public tokens (Unshield operation)

#### `createVoucherForRecipient(bytes32 secret, uint256 amount, address recipient, bytes32 recipientCommitment)`
Transfer portion of voucher to another user

#### `consolidate(bytes32[] secrets, bytes32 newCommitment)`
Merge multiple vouchers into single voucher

### View Functions

#### `getVoucherInfo(bytes32 commitment) → (bool exists, address token, uint256 amount, uint256 timestamp, bool spent)`
Get voucher details

#### `getMyVoucherBalance(bytes32 secret, address token) → uint256`
Check voucher balance for specific secret

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
| Consolidate (2) | ~170,000 | Two vouchers |
| Consolidate (10) | ~400,000 | Maximum vouchers |

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
- **Proxy**: `0x87de1BFddcEC6374B1b475e3D82E9539B150f987` ([View on PolygonScan](https://mumbai.polygonscan.com/address/0x87de1BFddcEC6374B1b475e3D82E9539B150f987)) 

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
└── LaserGun.test.js # Core tests
```

## Security Considerations

### Known Limitations
- Frontend must track user commitments locally
- Requires external secret sharing for transfers  
- Gas costs increase with number of vouchers to consolidate

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

## Links

- [Documentation](./docs/)
- [Security Policy](./docs/SECURITY.md)
- [Deployment Guide](./docs/DEPLOYMENT.md)
- [Upgrade Guide](./docs/UPGRADE.md)

## Disclaimer

This software is provided "as is" without warranty. Use at your own risk. Always conduct thorough testing before deploying to mainnet.