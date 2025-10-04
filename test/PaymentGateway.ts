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
  encodeAbiParameters,
  getAddress,
  keccak256,
  parseEther,
  stringToBytes,
  type TypedDataDomain,
  type TypedDataParameter,
  zeroAddress,
} from "viem";

const ContractName = "PaymentGateway" as const;
const ContractVersion = "1" as const;
const ChainType = "hardhat" as const;

const AMOUNT: bigint = parseEther("1");
const FEES: number = 1_000; // 10%.
const ORDER_ID = "demo" as const;

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

/**
 * Test scenario:
 * - The payer and has to pay 1.0 ETH to the merchant.
 * - The merchant is receiving 0.9 ETH.
 * - The backend signer is signing invoices off-chain.
 * - The fee recipient is receiving 0.1 ETH (10% fee).
 * - The PaymentGateway contract does not retain any ETH after the transaction.
 */
describe(ContractName, async () => {
  const connection: NetworkConnection<typeof ChainType> =
    await network.connect();
  const viem: HardhatViemHelpers<typeof ChainType> = connection.viem;
  const publicClient: GetPublicClientReturnType<typeof ChainType> =
    await viem.getPublicClient();

  it("Success scenario", async () => {
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

    // Compute invoice struct hash to use inside PayerBind.
    // fetch the contract's INVOICE_TYPE_HASH to avoid any mismatch.
    const invoiceTypeHash: Address = await gateway.read.INVOICE_TYPE_HASH();

    const encoded: Address = encodeAbiParameters(
      [
        { type: "bytes32" }, // Type hash.
        { type: "address" }, // Merchant.
        { type: "address" }, // Token.
        { type: "uint256" }, // Amount.
        { type: "uint16" }, // Fee basis points.
        { type: "address" }, // Fee recipient.
        { type: "uint256" }, // Expiry.
        { type: "uint256" }, // Nonce.
        { type: "bytes32" }, // Metadata hash.
      ],
      [
        invoiceTypeHash,
        getAddress(invoice.merchant),
        getAddress(invoice.token),
        invoice.amount,
        invoice.feeBasisPoints,
        getAddress(invoice.feeRecipient),
        invoice.expiry,
        invoice.nonce,
        invoice.metadataHash,
      ],
    );

    const payerSignature: Address = await payer.signTypedData({
      account: payer.account,
      domain: domain,
      types: { PayerBind: Types.PayerBind },
      primaryType: getKeyByValue(Types, Types.PayerBind),
      message: {
        invoiceHash: keccak256(encoded),
        payer: payerAddress,
      },
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
});
