# copilot-instructions.md

## Project Purpose

This repository implements a non-custodial Payment Gateway smart contract for EVM-compatible blockchains (Ethereum, etc.). The contract acts as an interface between merchants and payers, enabling secure payments with a small platform fee deducted per transaction. The platform never holds user funds; all transfers are direct and atomic.

## Technologies

- **Solidity**: Smart contract language for EVM.
- **HardHat**: Development, testing, and deployment framework.
- **TypeScript**: Used for scripts, deployment modules, and transaction utilities.
- **Prettier**: Code formatting for Solidity and TypeScript.

## Key Concepts

- **Non-custodial**: Platform does not hold funds; payments are routed directly.
- **Fee Mechanism**: Each transaction deducts a configurable fee, sent to the platform's fee recipient address.
- **Invoice Model**: Payments are initiated via signed invoices, specifying merchant, payer, amount, token, fee, expiry, and metadata.
- **Security**: EIP-712 signatures for invoice and payer binding, nonce tracking to prevent replay attacks, pausable contract logic, and reentrancy protection.

## Repository Structure

- `contracts/`: Contains Solidity smart contracts ([PaymentGateway.sol](contracts/PaymentGateway.sol)).
- `scripts/`: TypeScript scripts for transaction checks and utilities ([check-transaction.ts](scripts/check-transaction.ts)).
- `ignition/modules/`: TypeScript modules for contract deployment ([PaymentGateway.ts](ignition/modules/PaymentGateway.ts)).
- `.github/`, `.vscode/`, `.prettierrc`, `.gitignore`: Editor, formatting, and ignore settings.

## Coding Guidelines

- **TypeScript**: Use strict typing, ES2022+ features, and format with Prettier.
- **Solidity**: Use version ^0.8.28, follow OpenZeppelin best practices, and format with Prettier using `prettier-plugin-solidity`.
- **Formatting**: Always format code before committing. Solidity files use `prettier-plugin-solidity`; TypeScript uses Prettier.

## Smart Contract Design

- **Accounts**: Merchant, payer, and fee recipient addresses.
- **Instructions**:
  - `payInvoice`: Accepts a signed invoice, verifies signatures, checks expiry and nonce, splits payment, and emits events.
  - `setMaxFeeBasisPoints`, `setInvoiceSigner`: Owner-only functions to update fee and signer.
  - `pause`, `unpause`: Emergency controls for contract operations.
- **Events**: Emit `PaidInvoice` for successful payments.
- **Security**: Validate all inputs, check signatures, prevent reentrancy, and support pausing.

## Testing

- Write unit and integration tests in TypeScript and Solidity.
- Use HardHat for contract compilation, deployment, and testing.
- Use scripts in `scripts/` for simulating transactions and checking balances.

## Deployment

- Use HardHat and Ignition modules for building and deploying smart contracts.
- Store deployment artifacts and addresses for reference.

## Contribution

- Follow code formatting and documentation standards.
- Write clear, concise commit messages.
- Add tests for new features and bug fixes.
- Document public functions and contract logic.

## References

- [Solidity Docs](https://docs.soliditylang.org/)
- [HardHat](https://hardhat.org/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Prettier](https://prettier.io/)
- [TypeScript](https://www.typescriptlang.org/)
