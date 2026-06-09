# Ethereum and EVM-compatible

This project implements a smart contract for the Ethereum and all EVM-compatible blockchains that can be used as a payment gateway interface. It is secured against tampering, it transfers to multiple addresses, has payer lock available, and allows flexible platform fees.

## Compatibility

| OS                 | Status |
| ------------------ | ------ |
| macOS              | ✅     |
| Linux              | ✅     |
| Windows (via WSL2) | ✅     |
| Native Windows     | ✅     |

## Prerequisites

- [Node.JS](https://nodejs.org)
- HardHat

## Installation

```bash
bun run dependencies:install
```

## Usage

### Start local blockchain

```bash
bun run hardhat node
```

### Build

```bash
bun run hardhat compile
```

### Deploy

```bash
bun run hardhat ignition deploy ignition/modules/PaymentGateway.ts --network localhost
```

### Test

```bash
bun run hardhat test
```

## License

This project is licensed under the [MIT License](LICENSE).
