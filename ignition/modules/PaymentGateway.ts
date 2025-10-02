import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import {
  type IgnitionModule,
  type IgnitionModuleBuilder,
  type NamedArtifactContractDeploymentFuture,
} from "@nomicfoundation/ignition-core";
import { type Address } from "viem";

const CONTRACT_NAME: string = "PaymentGateway";
const SIGNER_ADDRESS: Address = "0x90f79bf6eb2c4f870365e785982e1f101e93b906";
const OWNER_ADDRESS: Address = "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc";

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
