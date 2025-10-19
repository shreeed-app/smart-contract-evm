import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import {
  type IgnitionModule,
  type IgnitionModuleBuilder,
  type NamedArtifactContractDeploymentFuture,
} from "@nomicfoundation/ignition-core";
import { type Address } from "viem";

const ContractName = "PaymentGateway" as const satisfies string;
const SignerAddress: Address = "0xfabb0ac9d68b0b445fb7357272ff202c5651694a";
const OwnerAddress: Address = "0x1cbd3b2770909d4e10f157cabc84c7264073c9ec";

const PaymentGateway: IgnitionModule = buildModule(
  ContractName,
  (module: IgnitionModuleBuilder) => {
    const paymentGateway: NamedArtifactContractDeploymentFuture<
      typeof ContractName
    > = module.contract(ContractName, [SignerAddress, OwnerAddress]);
    return { paymentGateway: paymentGateway };
  },
);

export default PaymentGateway;
