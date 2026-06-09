# Ethereum and EVM Smart Contract

Ethereum and all EVM-compatible blockchains smart contract for a payment gateway. Accepts direct payments and cross-chain bridge deposits, splits funds atomically between a merchant and a platform fee recipient, and verifies off-chain invoice signatures produced by an multi-party computation threshold engine via EIP-712.

## Usage

### Install

```bash
bun run dependencies:install
```

### Compile

```bash
bun run compile
```

### Start a local blockchain

```bash
bun run node
```

### Deploy to localhost

```bash
bun run deploy
```

The deployment module (`ignition/modules/PaymentGateway.ts`) deploys
the contract with the configured signer and owner addresses. Update
these values before deploying to a live network.

### Test

```bash
bun run test
```

### Lint

```bash
bun run lint:fix
```

### Format

```bash
bun run format
```

## License

This project is licensed under the [MIT License](LICENSE).
