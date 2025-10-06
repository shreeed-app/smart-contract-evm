import {
  type Address,
  createPublicClient,
  formatEther,
  type GetTransactionReturnType,
  http,
  type PublicClient,
  type TransactionReceipt,
} from "viem";
import { hardhat } from "viem/chains";

const TRANSACTION_HASH: Address = "0x";
const MERCHANT_ADDRESS: Address = "0x";
const FEE_RECIPIENT_ADDRESS: Address = "0x";

const main = async (): Promise<void> => {
  const client: PublicClient = createPublicClient({
    chain: hardhat,
    transport: http("http://127.0.0.1:8545"),
  });

  const receipt: TransactionReceipt = await client.getTransactionReceipt({
    hash: TRANSACTION_HASH,
  });

  const transaction: GetTransactionReturnType = await client.getTransaction({
    hash: TRANSACTION_HASH,
  });

  const sender: Address = transaction.from;
  const balanceSender: bigint = await client.getBalance({ address: sender });
  const balanceMerchant: bigint = await client.getBalance({
    address: MERCHANT_ADDRESS,
  });
  const balanceFeeRecipient: bigint = await client.getBalance({
    address: FEE_RECIPIENT_ADDRESS,
  });

  console.log("Status:", receipt.status);
  console.log("Balances after transaction:");
  console.log(`Sender (${sender}): (${formatEther(balanceSender)} ETH)`);
  console.log(`Merchant: (${formatEther(balanceMerchant)} ETH)`);
  console.log(`Fee recipient: (${formatEther(balanceFeeRecipient)} ETH)`);
};

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
