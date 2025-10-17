import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  type ContractReturnType,
  type GetPublicClientReturnType,
  type GetWalletClientReturnType,
  type HardhatViemHelpers,
} from "@nomicfoundation/hardhat-viem/types";
import { network } from "hardhat";
import { type NetworkConnection } from "hardhat/types/network";
import {
  type Address,
  getAddress,
  hashTypedData,
  keccak256,
  parseEther,
  stringToBytes,
  type TypedDataDomain,
  type TypedDataParameter,
  zeroAddress,
} from "viem";

const ContractName = "PaymentGateway" as const satisfies string;
const ContractVersion = "1" as const satisfies string;
const ChainType = "hardhat" as const satisfies string;

const AMOUNT: bigint = parseEther("1");
const FEES: number = 1_000; // 10%.
const ORDER_ID = "demo" as const satisfies string;

interface Invoice {
  merchant: Address;
  token: Address;
  amount: bigint;
  feeBasisPoints: number;
  feeRecipient: Address;
  expiry: bigint;
  nonce: bigint;
  metadataHash: Address;
}

const Types = {
  Invoice: [
    { name: "merchant", type: "address" },
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "feeBasisPoints", type: "uint16" },
    { name: "feeRecipient", type: "address" },
    { name: "expiry", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "metadataHash", type: "bytes32" },
  ],
  PayerBind: [
    { name: "invoiceHash", type: "bytes32" },
    { name: "payer", type: "address" },
  ],
} as const satisfies Record<string, TypedDataParameter[]>;

type KeyForValue<T, V> = {
  [K in keyof T]: [T[K]] extends [V] ? ([V] extends [T[K]] ? K : never) : never;
}[keyof T];

/**
 * Get the key of an object by its value.
 *
 * @param {T} object - The object to search.
 * @param {V} value - The value to search for.
 * @returns {KeyForValue<T, V>} - The key corresponding to the value.
 */
const getKeyByValue = <
  T extends Record<string, unknown>,
  const V extends T[keyof T],
>(
  object: T,
  value: V,
): KeyForValue<T, V> => {
  return Object.keys(object).find(
    (key: string) => object[key as keyof T] === value,
  )! as KeyForValue<T, V>;
};

describe(ContractName, async (): Promise<void> => {
  const connection: NetworkConnection<typeof ChainType> =
    await network.connect();
  const viem: HardhatViemHelpers<typeof ChainType> = connection.viem;
  const publicClient: GetPublicClientReturnType<typeof ChainType> =
    await viem.getPublicClient();

  /**
   * Test scenario:
   * - The payer and has to pay 1.0 ETH to the merchant.
   * - The merchant is receiving 0.9 ETH.
   * - The backend signer is signing invoices off-chain.
   * - The fee recipient is receiving 0.1 ETH (10% fee).
   * - The PaymentGateway contract does not retain any ETH after the
   *   transaction.
   */
  it("Success scenario.", async (): Promise<void> => {
    const [owner, payer, merchant, signer, recipient]: Array<
      GetWalletClientReturnType<typeof ChainType>
    > = await viem.getWalletClients();

    const ownerAddress: Address = getAddress(owner.account.address);
    const signerAddress: Address = getAddress(signer.account.address);
    const payerAddress: Address = getAddress(payer.account.address);
    const merchantAddress: Address = getAddress(merchant.account.address);
    const recipientAddress: Address = getAddress(recipient.account.address);

    const chainId: number = await publicClient.getChainId();

    // constructor(address _invoiceSigner, address _owner)
    const gateway: ContractReturnType<typeof ContractName> =
      await viem.deployContract(ContractName, [signerAddress, ownerAddress]);
    const gatewayAddress: Address = getAddress(gateway.address);

    // Verify if deployed correctly.
    const invoiceSigner: Address = await gateway.read.invoiceSigner();
    assert.equal(getAddress(invoiceSigner), signerAddress);
    assert.equal(await gateway.read.maxFeeBasisPoints(), FEES);

    const invoice: Invoice = {
      merchant: merchantAddress,
      token: zeroAddress,
      amount: AMOUNT,
      feeBasisPoints: FEES,
      feeRecipient: recipientAddress,
      expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
      nonce: BigInt.asUintN(64, BigInt(Date.now())),
      metadataHash: keccak256(stringToBytes(ORDER_ID)),
    };

    const domain: TypedDataDomain = {
      name: ContractName,
      version: ContractVersion,
      chainId: chainId,
      verifyingContract: gatewayAddress,
    };

    // Signer signs the invoice (backend signature).
    const backendSignature: Address = await signer.signTypedData({
      account: signer.account,
      domain: domain,
      types: { Invoice: Types.Invoice },
      primaryType: getKeyByValue(Types, Types.Invoice),
      message: invoice,
    });

    // Verify invoice digest consistency between on-chain and off-chain.
    const onChainDigest: Address = await gateway.read.invoiceDigest([invoice]);
    const offChainDigest: Address = hashTypedData({
      domain: domain,
      types: { Invoice: Types.Invoice },
      primaryType: getKeyByValue(Types, Types.Invoice),
      message: invoice,
    });
    assert.equal(offChainDigest, onChainDigest, "Invoice digest mismatch.");

    // Payer signs the binding to the invoice.
    const hash: Address = await gateway.read.invoiceStructHash([invoice]);
    const payerSignature: Address = await payer.signTypedData({
      account: payer.account,
      domain: domain,
      types: { PayerBind: Types.PayerBind },
      primaryType: getKeyByValue(Types, Types.PayerBind),
      message: { invoiceHash: hash, payer: payerAddress },
    });

    const merchantBalanceBefore: bigint = await publicClient.getBalance({
      address: merchantAddress,
    });
    const recipientBalanceBefore: bigint = await publicClient.getBalance({
      address: recipientAddress,
    });
    const gatewayBalanceBefore: bigint = await publicClient.getBalance({
      address: gatewayAddress,
    });

    await viem.assertions.emitWithArgs(
      gateway.write.payInvoice(
        [invoice, backendSignature, payerAddress, payerSignature],
        { value: AMOUNT, account: payer.account },
      ),
      gateway,
      "PaidInvoice",
      [
        {
          payer: payerAddress,
          merchant: merchantAddress,
          token: getAddress(invoice.token),
          amount: invoice.amount,
          feeBasisPoints: invoice.feeBasisPoints,
          feeRecipient: getAddress(invoice.feeRecipient),
          metadataHash: invoice.metadataHash,
          nonce: invoice.nonce,
        },
      ],
    );

    const merchantBalanceAfter: bigint = await publicClient.getBalance({
      address: merchantAddress,
    });
    const recipientBalanceAfter: bigint = await publicClient.getBalance({
      address: recipientAddress,
    });
    const gatewayBalanceAfter: bigint = await publicClient.getBalance({
      address: gatewayAddress,
    });

    const fee: bigint = (invoice.amount * 1000n) / 10000n; // 0.1 ETH.

    assert.equal(
      merchantBalanceAfter - merchantBalanceBefore,
      invoice.amount - fee,
      "Merchant should receive 0.9 ETH.",
    );
    assert.equal(
      recipientBalanceAfter - recipientBalanceBefore,
      fee,
      "Platform should receive 0.1 ETH.",
    );
    assert.equal(
      gatewayBalanceAfter - gatewayBalanceBefore,
      0n,
      "Contract should not retain ETH.",
    );

    assert.equal(await gateway.read.usedNonces([invoice.nonce]), true);
  });

  it("Invalid payer.", async (): Promise<void> => {
    const [owner, payer, merchant, signer, recipient]: Array<
      GetWalletClientReturnType<typeof ChainType>
    > = await viem.getWalletClients();

    const ownerAddress: Address = getAddress(owner.account.address);
    const signerAddress: Address = getAddress(signer.account.address);
    const payerAddress: Address = getAddress(payer.account.address);
    const merchantAddress: Address = getAddress(merchant.account.address);
    const recipientAddress: Address = getAddress(recipient.account.address);

    const chainId: number = await publicClient.getChainId();

    // constructor(address _invoiceSigner, address _owner)
    const gateway: ContractReturnType<typeof ContractName> =
      await viem.deployContract(ContractName, [signerAddress, ownerAddress]);
    const gatewayAddress: Address = getAddress(gateway.address);

    const invoiceSigner: Address = await gateway.read.invoiceSigner();
    assert.equal(getAddress(invoiceSigner), signerAddress);
    assert.equal(await gateway.read.maxFeeBasisPoints(), FEES);

    const invoice: Invoice = {
      merchant: merchantAddress,
      token: zeroAddress,
      amount: AMOUNT,
      feeBasisPoints: FEES,
      feeRecipient: recipientAddress,
      expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
      nonce: BigInt.asUintN(64, BigInt(Date.now())),
      metadataHash: keccak256(stringToBytes(ORDER_ID)),
    };

    const domain: TypedDataDomain = {
      name: ContractName,
      version: ContractVersion,
      chainId,
      verifyingContract: gatewayAddress,
    };

    // Backend signs invoice (correct signer)
    const backendSignature: Address = await signer.signTypedData({
      account: signer.account,
      domain: domain,
      types: { Invoice: Types.Invoice },
      primaryType: getKeyByValue(Types, Types.Invoice),
      message: invoice,
    });

    // Cross-check invoice digest off-chain vs on-chain.
    const onChainDigest: Address = await gateway.read.invoiceDigest([invoice]);
    const offChainDigest: Address = hashTypedData({
      domain: domain,
      types: { Invoice: Types.Invoice },
      primaryType: getKeyByValue(Types, Types.Invoice),
      message: invoice,
    });
    assert.equal(offChainDigest, onChainDigest, "Invoice digest mismatch.");

    // Payer bind (signed by the *real* payer).
    const invoiceHash: Address = await gateway.read.invoiceStructHash([
      invoice,
    ]);
    const payerSignature: Address = await payer.signTypedData({
      account: payer.account,
      domain,
      types: { PayerBind: Types.PayerBind },
      primaryType: getKeyByValue(Types, Types.PayerBind),
      message: { invoiceHash: invoiceHash, payer: payerAddress },
    });

    await assert.rejects(
      (async (): Promise<Address> => {
        return await gateway.write.payInvoice(
          [invoice, backendSignature, payerAddress, payerSignature],
          // Wrong sender is paying the invoice.
          { value: AMOUNT, account: owner.account },
        );
      })(),
      /unauthorized payer/i,
    );

    const used: boolean = await gateway.read.usedNonces([invoice.nonce]);
    assert.equal(used, false, "Nonce consumed on unauthorized payer.");
  });

  it("Tampered invoice data.", async (): Promise<void> => {
    const [owner, payer, merchant, signer, recipient]: Array<
      GetWalletClientReturnType<typeof ChainType>
    > = await viem.getWalletClients();

    const ownerAddress: Address = getAddress(owner.account.address);
    const signerAddress: Address = getAddress(signer.account.address);
    const payerAddress: Address = getAddress(payer.account.address);
    const merchantAddress: Address = getAddress(merchant.account.address);
    const recipientAddress: Address = getAddress(recipient.account.address);

    const chainId: number = await publicClient.getChainId();

    const gateway: ContractReturnType<typeof ContractName> =
      await viem.deployContract(ContractName, [signerAddress, ownerAddress]);
    const gatewayAddress: Address = getAddress(gateway.address);

    const invoiceSigner: Address = await gateway.read.invoiceSigner();
    assert.equal(getAddress(invoiceSigner), signerAddress);
    assert.equal(await gateway.read.maxFeeBasisPoints(), FEES);

    const invoice: Invoice = {
      merchant: merchantAddress,
      token: zeroAddress,
      amount: AMOUNT,
      feeBasisPoints: FEES,
      feeRecipient: recipientAddress,
      expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
      nonce: BigInt.asUintN(64, BigInt(Date.now())),
      metadataHash: keccak256(stringToBytes(ORDER_ID)),
    };

    const domain: TypedDataDomain = {
      name: ContractName,
      version: ContractVersion,
      chainId,
      verifyingContract: gatewayAddress,
    };

    const backendSignature: Address = await signer.signTypedData({
      account: signer.account,
      domain,
      types: { Invoice: Types.Invoice },
      primaryType: getKeyByValue(Types, Types.Invoice),
      message: invoice,
    });

    const onChainDigest: Address = await gateway.read.invoiceDigest([invoice]);
    const offChainDigest: Address = hashTypedData({
      domain,
      types: { Invoice: Types.Invoice },
      primaryType: getKeyByValue(Types, Types.Invoice),
      message: invoice,
    });
    assert.equal(offChainDigest, onChainDigest, "Invoice digest mismatch.");

    const invoiceTampered: Invoice = {
      ...invoice,
      amount: AMOUNT * 2n,
    };

    const tamperedStructHash: Address = await gateway.read.invoiceStructHash([
      invoiceTampered,
    ]);
    const payerSignature: Address = await payer.signTypedData({
      account: payer.account,
      domain,
      types: { PayerBind: Types.PayerBind },
      primaryType: getKeyByValue(Types, Types.PayerBind),
      message: { invoiceHash: tamperedStructHash, payer: payerAddress },
    });

    await assert.rejects(
      (async (): Promise<Address> => {
        return await gateway.write.payInvoice(
          [invoiceTampered, backendSignature, payerAddress, payerSignature],
          // Paying according to tampered invoice.
          { value: invoiceTampered.amount, account: payer.account },
        );
      })(),
      /incorrect backend signature/i,
    );

    const used: boolean = await gateway.read.usedNonces([invoice.nonce]);
    assert.equal(used, false, "Nonce consumed with invalid signature.");
  });
});
