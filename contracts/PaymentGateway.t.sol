// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "./PaymentGateway.sol";

contract PaymentGatewayTest is Test {
    using stdStorage for StdStorage;

    uint256 private OWNER_PRIVATE_KEY = 0xA11CE;
    uint256 private PAYER_PRIVATE_KEY = 0xB0B;
    uint256 private MERCHANT_PRIVATE_KEY = 0xC0DE;
    uint256 private SIGNER_PRIVATE_KEY = 0xD00D;
    uint256 private RECIPIENT_PRIVATE_KEY = 0xFEE;

    address private owner;
    address private payer;
    address private merchant;
    address private signer;
    address private recipient;

    PaymentGateway private gateway;

    uint16 constant FEES = 1000;
    uint256 constant AMOUNT = 1 ether;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "EIP712Domain(",
                "string name,",
                "string version,",
                "uint256 chainId,",
                "address verifyingContract",
                ")"
            )
        );

    // Contract information.
    bytes32 private constant NAME_HASH = keccak256(bytes("PaymentGateway"));
    bytes32 private constant VERSION_HASH = keccak256(bytes("1"));

    function setUp() public {
        owner = vm.addr(OWNER_PRIVATE_KEY);
        payer = vm.addr(PAYER_PRIVATE_KEY);
        merchant = vm.addr(MERCHANT_PRIVATE_KEY);
        signer = vm.addr(SIGNER_PRIVATE_KEY);
        recipient = vm.addr(RECIPIENT_PRIVATE_KEY);

        // Fund test wallets.
        vm.deal(payer, 100 ether);
        vm.deal(owner, 100 ether);
        vm.deal(merchant, 0);
        vm.deal(recipient, 0);

        // Deploy the contract.
        vm.prank(owner);
        gateway = new PaymentGateway(signer, owner);

        assertEq(gateway.invoiceSigner(), signer, "invoiceSigner mismatch");
        assertEq(gateway.maxFeeBasisPoints(), FEES);
    }

    /**
     * @dev Test a successful invoice payment.
     * The test covers the following steps:
     * 1. Create an invoice struct with the necessary details.
     * 2. Hash the invoice struct and create a digest for signing.
     * 3. Sign the invoice digest with the backend signer's private key.
     * 4. Create a payer bind struct hash and digest.
     * 5. Sign the bind digest with the payer's private key.
     * 6. Record balances before the payment.
     * 7. Expect the PaidInvoice event to be emitted.
     * 8. Call the payInvoice function with the invoice, backend signature,
     *    payer, and payer signature.
     * 9. Record balances after the payment.
     * 10. Calculate expected fee and amounts to merchant and recipient.
     * 11. Assert that the balances have changed as expected.
     */
    function test_success() public {
        PaymentGateway.Invoice memory invoice;
        invoice.merchant = merchant;
        invoice.token = gateway.NATIVE();
        invoice.amount = AMOUNT;
        invoice.feeBasisPoints = FEES;
        invoice.feeRecipient = recipient;
        invoice.expiry = block.timestamp + 1 hours;
        invoice.nonce = uint256(
            keccak256(
                abi.encodePacked("nonce", block.timestamp, address(this))
            )
        );
        invoice.metadataHash = keccak256(bytes("demo"));

        // Sign the invoice.
        bytes32 invoiceStructHash = _invoiceStructHash(invoice);
        bytes32 domainSeparator = _domainSeparator(address(gateway));
        bytes32 invoiceDigest = keccak256(
            // \x19\x01 is the standard encoding prefix.
            abi.encodePacked("\x19\x01", domainSeparator, invoiceStructHash)
        );

        // Sign with the backend signer key.
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(
            SIGNER_PRIVATE_KEY,
            invoiceDigest
        );
        bytes memory backendSignature = abi.encodePacked(r1, s1, v1);

        // keccak256(abi.encode(PAYER_BIND_TYPE_HASH, invoiceHash, payer))
        bytes32 payerBindTypeHash = gateway.PAYER_BIND_TYPE_HASH();
        bytes32 bindStructHash = keccak256(
            abi.encode(payerBindTypeHash, invoiceStructHash, payer)
        );
        bytes32 bindDigest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, bindStructHash)
        );

        // Sign with the payer key.
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(
            PAYER_PRIVATE_KEY,
            bindDigest
        );
        bytes memory payerSignature = abi.encodePacked(r2, s2, v2);

        uint256 merchantBalanceBefore = merchant.balance;
        uint256 recipientBalanceBefore = recipient.balance;
        uint256 contractBalanceBefore = address(gateway).balance;

        vm.expectEmit(true, true, true, true, address(gateway));
        PaymentGateway._PaidInvoice memory expected = PaymentGateway
            ._PaidInvoice({
                payer: payer,
                merchant: invoice.merchant,
                token: invoice.token,
                amount: invoice.amount,
                feeBasisPoints: invoice.feeBasisPoints,
                feeRecipient: invoice.feeRecipient,
                metadataHash: invoice.metadataHash,
                nonce: invoice.nonce
            });
        emit PaymentGateway.PaidInvoice(expected);

        // Pay the invoice.
        vm.prank(payer);
        gateway.payInvoice{ value: AMOUNT }(
            invoice,
            backendSignature,
            payer,
            payerSignature
        );

        uint256 merchantBalanceAfter = merchant.balance;
        uint256 recipientBalanceAfter = recipient.balance;
        uint256 contractBalanceAfter = address(gateway).balance;

        uint256 fee = (AMOUNT * FEES) / 10_000; // 0.1 ETH.
        uint256 toMerchant = AMOUNT - fee; // 0.9 ETH.

        assertEq(
            merchantBalanceAfter - merchantBalanceBefore,
            toMerchant,
            "merchant should receive 0.9 ETH."
        );
        assertEq(
            recipientBalanceAfter - recipientBalanceBefore,
            fee,
            "platform should receive 0.1 ETH."
        );
        assertEq(
            contractBalanceAfter - contractBalanceBefore,
            0,
            "contract should not retain ETH."
        );

        assertTrue(gateway.usedNonces(invoice.nonce));
    }

    /**
     * @dev Test that the payment reverts when an unauthorized payer attempts
     * to pay an invoice.
     * The test covers the following steps:
     * 1. Create an invoice struct with the necessary details.
     * 2. Hash the invoice struct and create a digest for signing.
     * 3. Sign the invoice digest with the backend signer's private key.
     * 4. Create a payer bind struct hash and digest using a different payer
     *    address.
     * 5. Sign the bind digest with the payer's private key.
     * 6. Expect the payInvoice function to revert with "unauthorized payer".
     * 7. Call the payInvoice function with the invoice, backend signature,
     *    unauthorized payer, and payer signature.
     * 8. The test passes if the revert occurs as expected.
     */
    function test_revert() public {
        PaymentGateway.Invoice memory invoice;
        invoice.merchant = merchant;
        invoice.token = gateway.NATIVE();
        invoice.amount = AMOUNT;
        invoice.feeBasisPoints = FEES;
        invoice.feeRecipient = recipient;
        invoice.expiry = block.timestamp + 1 hours;
        invoice.nonce = uint256(
            keccak256(abi.encodePacked("nonce2", block.timestamp))
        );
        invoice.metadataHash = keccak256(bytes("demo-2"));

        // Sign the invoice.
        bytes32 domainSeparator = _domainSeparator(address(gateway));
        bytes32 invoiceStructHash = _invoiceStructHash(invoice);
        bytes32 invoiceDigest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, invoiceStructHash)
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(
            SIGNER_PRIVATE_KEY,
            invoiceDigest
        );
        bytes memory backendSignature = abi.encodePacked(r1, s1, v1);

        // Sign with a different payer key.
        bytes32 bindStructHash = keccak256(
            abi.encode(
                gateway.PAYER_BIND_TYPE_HASH(),
                invoiceStructHash,
                payer
            )
        );
        bytes32 bindDigest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, bindStructHash)
        );
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(
            PAYER_PRIVATE_KEY,
            bindDigest
        );
        bytes memory payerSignature = abi.encodePacked(r2, s2, v2);

        // Attempt to pay the invoice from an unauthorized payer (owner).
        vm.prank(owner);
        vm.expectRevert(bytes("unauthorized payer"));
        gateway.payInvoice{ value: AMOUNT }(
            invoice,
            backendSignature,
            payer,
            payerSignature
        );
    }

    /**
     * @dev Compute the EIP-712 domain separator for the contract.
     * @param verifyingContract The contract address verifying the signature.
     * @return The computed domain separator as a bytes32 value.
     */
    function _domainSeparator(
        address verifyingContract
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    NAME_HASH,
                    VERSION_HASH,
                    block.chainid,
                    verifyingContract
                )
            );
    }

    /**
     * @dev Compute the struct hash for a PaymentGateway.Invoice.
     * @param invoice The invoice struct to hash.
     * @return The computed struct hash as a bytes32 value.
     */
    function _invoiceStructHash(
        PaymentGateway.Invoice memory invoice
    ) internal view returns (bytes32) {
        bytes32 typeHash = gateway.INVOICE_TYPE_HASH();
        return
            keccak256(
                abi.encode(
                    typeHash,
                    invoice.merchant,
                    invoice.token,
                    invoice.amount,
                    invoice.feeBasisPoints,
                    invoice.feeRecipient,
                    invoice.expiry,
                    invoice.nonce,
                    invoice.metadataHash
                )
            );
    }
}
