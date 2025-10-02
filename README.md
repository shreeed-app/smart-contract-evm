# Cryptocurrency Payment Gateway – EVM Smart Contract

This repository implements a non-custodial Payment Gateway smart contract for EVM-compatible blockchains (Ethereum, etc.). The contract acts as an interface between merchants and payers, enabling secure payments with a small platform fee deducted per transaction. The platform never holds user funds; all transfers are direct and atomic.

## Features

- Non-custodial payments (ETH or ERC20)
- Configurable platform fee
- Invoice-based payment flow with EIP-712 signatures
- Payer binding and replay protection (nonce)
- Pausable and secure (reentrancy guard)
- TypeScript scripts for deployment and transaction checks

## Technologies

- Solidity (^0.8.28)
- HardHat (development, testing, deployment)
- TypeScript (scripts, deployment modules)
- Prettier + prettier-plugin-solidity (formatting)
- OpenZeppelin Contracts (security)

## Project Structure

- [`contracts/PaymentGateway.sol`](contracts/PaymentGateway.sol): Main smart contract
- [`ignition/modules/PaymentGateway.ts`](ignition/modules/PaymentGateway.ts): HardHat Ignition deployment module
- [`scripts/check-transaction.ts`](scripts/check-transaction.ts): TypeScript script to check transaction status and balances
- `.github/`, `.vscode/`, `.prettierrc`, `.gitignore`: Configuration and formatting

## Prerequisites

- Node.js >= 18
- pnpm (recommended) or npm
- HardHat CLI
- TypeScript

## Installation

```sh
pnpm install
# or
npm install
```

## Build Contracts

```sh
pnpm hardhat compile
# or
npx hardhat compile
```

## Deployment

You can deploy the contract using HardHat Ignition:

```sh
pnpm hardhat ignition deploy ignition/modules/PaymentGateway.ts
```

- Edit [`ignition/modules/PaymentGateway.ts`](ignition/modules/PaymentGateway.ts) to set the initial signer and owner addresses.

## Usage

### Payment Flow

1. **Invoice Creation**: Backend generates an invoice struct and signs it (EIP-712) with the platform signer key.
2. **Payer Binding (optional)**: If the invoice is locked to a payer, the payer signs the invoice hash.
3. **Payment**: The payer calls `payInvoice` on the contract, providing the invoice, backend signature, payer address, and payer signature (if required).
4. **Funds Split**: The contract splits the payment between merchant and fee recipient, emits a `PaidInvoice` event.

### Checking Transactions

Use the provided script to check balances after a transaction:

```sh
pnpm tsx scripts/check-transaction.ts
```

Edit [`scripts/check-transaction.ts`](scripts/check-transaction.ts) to set the transaction hash, merchant, and fee recipient addresses.

## Testing

Write tests in TypeScript or Solidity. Run tests with:

```sh
pnpm hardhat test
```

## Formatting

Format Solidity and TypeScript files with Prettier:

```sh
pnpm prettier --write .
```

## Configuration

- Solidity formatting is configured in `.prettierrc`
- Editor settings in `.vscode/settings.json`
- HardHat config in [`hardhat.config.ts`](hardhat.config.ts)

## Security

- Uses OpenZeppelin's Ownable, ReentrancyGuard, Pausable, EIP712, and SafeERC20
- All payments are atomic and non-custodial
- Nonce tracking prevents replay attacks
- Contract can be paused by owner

## References

- [Solidity Docs](https://docs.soliditylang.org/)
- [HardHat](https://hardhat.org/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Prettier](https://prettier.io/)
- [TypeScript](https://www.typescriptlang.org/)
