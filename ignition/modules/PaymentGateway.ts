import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import {
  type IgnitionModule,
  type IgnitionModuleBuilder,
  type NamedArtifactContractDeploymentFuture,
} from "@nomicfoundation/ignition-core";
import { type Address } from "viem";

const CONTRACT_NAME: string = "PaymentGateway";
const SIGNER_ADDRESS: Address = "0xfabb0ac9d68b0b445fb7357272ff202c5651694a";
const OWNER_ADDRESS: Address = "0x1cbd3b2770909d4e10f157cabc84c7264073c9ec";

const PaymentGateway: IgnitionModule = buildModule(
  CONTRACT_NAME,
  (module: IgnitionModuleBuilder) => {
    const paymentGateway: NamedArtifactContractDeploymentFuture<
      typeof CONTRACT_NAME
    > = module.contract(CONTRACT_NAME, [SIGNER_ADDRESS, OWNER_ADDRESS]);
    return { paymentGateway: paymentGateway };
  },
);

export default PaymentGateway;
