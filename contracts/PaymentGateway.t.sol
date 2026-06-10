// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./PaymentGateway.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PaymentGatewayTest is Test {
    uint256 private constant OWNER_KEY = 0xA11CE;
    uint256 private constant FIRST_PAYER_KEY = 0xB0B;
    uint256 private constant SECOND_PAYER_KEY = 0xB0B2;
    uint256 private constant MERCHANT_KEY = 0xC0DE;
    uint256 private constant FIRST_SIGNER_KEY = 0xD00D;
    uint256 private constant SECOND_SIGNER_KEY = 0xD00D2;
    uint256 private constant FEE_KEY = 0xFEE;
    uint256 private constant RELAYER_KEY = 0x5AFE;

    address private owner;
    address private firstPayer;
    address private secondPayer;
    address private merchant;
    address private firstSigner;
    address private secondSigner;
    address private feeRecipient;
    address private relayer;

    PaymentGateway private gateway;
    MockUSDC private usdc;

    uint16 private constant FEES = 1000;
    uint256 private constant AMOUNT = 1 ether;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        firstPayer = vm.addr(FIRST_PAYER_KEY);
        secondPayer = vm.addr(SECOND_PAYER_KEY);
        merchant = vm.addr(MERCHANT_KEY);
        firstSigner = vm.addr(FIRST_SIGNER_KEY);
        secondSigner = vm.addr(SECOND_SIGNER_KEY);
        feeRecipient = vm.addr(FEE_KEY);
        relayer = vm.addr(RELAYER_KEY);

        vm.deal(firstPayer, 100 ether);
        vm.deal(secondPayer, 100 ether);
        vm.deal(owner, 100 ether);
        vm.deal(relayer, 100 ether);

        usdc = new MockUSDC();

        vm.prank(owner);
        gateway = new PaymentGateway(firstSigner, owner);

        usdc.mint(firstPayer, 1_000_000 * 1e18);
        usdc.mint(secondPayer, 1_000_000 * 1e18);
        usdc.mint(relayer, 1_000_000 * 1e18);
        vm.prank(firstPayer);
        usdc.approve(address(gateway), type(uint256).max);
        vm.prank(secondPayer);
        usdc.approve(address(gateway), type(uint256).max);
        vm.prank(relayer);
        usdc.approve(address(gateway), type(uint256).max);
    }

    function _invoice(address token)
        internal
        view
        returns (PaymentGateway.Invoice memory)
    {
        return PaymentGateway.Invoice({
            merchant: merchant,
            token: token,
            amount: AMOUNT,
            feeBasisPoints: FEES,
            feeRecipient: feeRecipient,
            expiry: block.timestamp + 1 hours,
            nonce: uint256(
                keccak256(abi.encodePacked(block.timestamp, gasleft()))
            ),
            metadataHash: keccak256("test")
        });
    }

    function _sign(PaymentGateway.Invoice memory invoice)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                gateway.domainSeparator(),
                gateway.invoiceStructHash(invoice)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FIRST_SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signPayerBind(
        PaymentGateway.Invoice memory invoice,
        address payerAddress
    ) internal view returns (bytes memory) {
        bytes32 invoiceHash = gateway.invoiceStructHash(invoice);
        bytes32 bindStructHash = keccak256(
            abi.encode(
                gateway.PAYER_BIND_TYPE_HASH(), invoiceHash, payerAddress
            )
        );
        bytes32 bindDigest = keccak256(
            abi.encodePacked(
                "\x19\x01", gateway.domainSeparator(), bindStructHash
            )
        );
        uint256 key =
            payerAddress == firstPayer ? FIRST_PAYER_KEY : SECOND_PAYER_KEY;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, bindDigest);
        return abi.encodePacked(r, s, v);
    }

    function _split(uint256 amount, uint16 basisPoints)
        internal
        pure
        returns (uint256 toMerchant, uint256 fee)
    {
        fee = (amount * basisPoints) / 10_000;
        toMerchant = amount - fee;
    }

    function test_deploymentState() public view {
        assertEq(gateway.invoiceSigner(), firstSigner);
        assertEq(gateway.owner(), owner);
        assertEq(gateway.maxFeeBasisPoints(), FEES);
        assertEq(gateway.pendingInvoiceSigner(), address(0));
        assertEq(gateway.signerUpdateScheduledAt(), 0);
        assertFalse(gateway.paused());
    }

    function test_deployRevertsZeroSigner() public {
        vm.expectRevert("invoiceSigner = 0");
        new PaymentGateway(address(0), owner);
    }

    function test_deployRevertsZeroOwner() public {
        vm.expectRevert();
        new PaymentGateway(firstSigner, address(0));
    }

    function test_payInvoiceETH() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory backendSignature = _sign(invoice);
        bytes memory payerSignature = _signPayerBind(invoice, firstPayer);

        uint256 merchantBalance = merchant.balance;
        uint256 feeRecipientBalance = feeRecipient.balance;

        vm.expectEmit(true, true, true, true, address(gateway));
        emit PaymentGateway.InvoicePaid(
            firstPayer,
            invoice.merchant,
            gateway.NATIVE(),
            invoice.amount,
            invoice.feeBasisPoints,
            invoice.feeRecipient,
            invoice.metadataHash,
            invoice.nonce
        );

        vm.prank(firstPayer);
        gateway.payInvoice{ value: AMOUNT }(
            invoice, backendSignature, firstPayer, payerSignature
        );

        (uint256 toMerchant, uint256 fee) = _split(AMOUNT, FEES);
        assertEq(merchant.balance - merchantBalance, toMerchant);
        assertEq(feeRecipient.balance - feeRecipientBalance, fee);
        assertEq(address(gateway).balance, 0);
        assertTrue(gateway.usedNonces(invoice.nonce));
    }

    function test_payInvoiceETH_Open() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory signature = _sign(invoice);

        vm.prank(secondPayer);
        gateway.payInvoice{ value: AMOUNT }(invoice, signature, address(0), "");

        (uint256 toMerchant,) = _split(AMOUNT, FEES);
        assertEq(merchant.balance, toMerchant);
        assertTrue(gateway.usedNonces(invoice.nonce));
    }

    function test_payInvoiceETH_WrongValue() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory signature = _sign(invoice);

        vm.prank(firstPayer);
        vm.expectRevert("wrong ETH amount");
        gateway.payInvoice{ value: AMOUNT - 1 }(
            invoice, signature, address(0), ""
        );
    }

    function test_payInvoiceERC20() public {
        PaymentGateway.Invoice memory invoice = _invoice(address(usdc));
        bytes memory backendSignature = _sign(invoice);
        bytes memory payerSignature = _signPayerBind(invoice, firstPayer);

        (uint256 toMerchant, uint256 fee) = _split(AMOUNT, FEES);

        vm.prank(firstPayer);
        gateway.payInvoice(
            invoice, backendSignature, firstPayer, payerSignature
        );

        assertEq(usdc.balanceOf(merchant), toMerchant);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(address(gateway)), 0);
    }

    function test_payInvoice_RevertUnauthorized() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory backendSignature = _sign(invoice);
        bytes memory payerSignature = _signPayerBind(invoice, firstPayer);

        vm.prank(secondPayer);
        vm.expectRevert("unauthorized payer");
        gateway.payInvoice{ value: AMOUNT }(
            invoice, backendSignature, firstPayer, payerSignature
        );
    }

    function test_payInvoice_RevertBadPayerSignature() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory backendSignature = _sign(invoice);
        bytes memory payerSignature = _signPayerBind(invoice, secondPayer);

        vm.prank(firstPayer);
        vm.expectRevert("invalid payer signature");
        gateway.payInvoice{ value: AMOUNT }(
            invoice, backendSignature, firstPayer, payerSignature
        );
    }

    function test_fulfillInvoiceETH() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory signature = _sign(invoice);

        uint256 merchantBalance = merchant.balance;
        uint256 feeRecipientBalance = feeRecipient.balance;

        vm.expectEmit(true, true, true, true, address(gateway));
        emit PaymentGateway.InvoicePaid(
            relayer,
            invoice.merchant,
            gateway.NATIVE(),
            invoice.amount,
            invoice.feeBasisPoints,
            invoice.feeRecipient,
            invoice.metadataHash,
            invoice.nonce
        );

        vm.prank(relayer);
        gateway.fulfillInvoice{ value: AMOUNT }(invoice, signature);

        (uint256 toMerchant, uint256 fee) = _split(AMOUNT, FEES);
        assertEq(merchant.balance - merchantBalance, toMerchant);
        assertEq(feeRecipient.balance - feeRecipientBalance, fee);
        assertEq(address(gateway).balance, 0);
        assertTrue(gateway.usedNonces(invoice.nonce));
    }

    function test_fulfillInvoiceETH_WrongValue() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory signature = _sign(invoice);

        vm.prank(relayer);
        vm.expectRevert("wrong ETH amount");
        gateway.fulfillInvoice{ value: AMOUNT - 1 }(invoice, signature);
    }

    function test_fulfillInvoiceERC20() public {
        vm.prank(relayer);
        usdc.transfer(address(gateway), AMOUNT);
        assertEq(usdc.balanceOf(address(gateway)), AMOUNT);

        PaymentGateway.Invoice memory invoice = _invoice(address(usdc));
        bytes memory signature = _sign(invoice);

        vm.prank(relayer);
        gateway.fulfillInvoice(invoice, signature);

        (uint256 toMerchant, uint256 fee) = _split(AMOUNT, FEES);
        assertEq(usdc.balanceOf(merchant), toMerchant);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(address(gateway)), 0);
        assertTrue(gateway.usedNonces(invoice.nonce));
    }

    function test_revertExpired() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        invoice.expiry = block.timestamp - 1;
        bytes memory signature = _sign(invoice);

        vm.prank(firstPayer);
        vm.expectRevert("expired");
        gateway.payInvoice{ value: AMOUNT }(invoice, signature, address(0), "");
    }

    function test_revertNonceReused() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory signature = _sign(invoice);

        vm.prank(firstPayer);
        gateway.payInvoice{ value: AMOUNT }(invoice, signature, address(0), "");

        vm.prank(secondPayer);
        vm.expectRevert("nonce used");
        gateway.payInvoice{ value: AMOUNT }(invoice, signature, address(0), "");
    }

    function test_revertBadInvoiceSignature() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                gateway.domainSeparator(),
                gateway.invoiceStructHash(invoice)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, digest);
        bytes memory badSignature = abi.encodePacked(r, s, v);

        vm.prank(firstPayer);
        vm.expectRevert("invalid invoice signature");
        gateway.payInvoice{ value: AMOUNT }(
            invoice, badSignature, address(0), ""
        );
    }

    function test_revertZeroMerchant() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        invoice.merchant = address(0);
        bytes memory signature = _sign(invoice);

        vm.prank(firstPayer);
        vm.expectRevert("merchant = 0");
        gateway.payInvoice{ value: AMOUNT }(invoice, signature, address(0), "");
    }

    function test_revertZeroFeeRecipient() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        invoice.feeRecipient = address(0);
        bytes memory signature = _sign(invoice);

        vm.prank(firstPayer);
        vm.expectRevert("feeRecipient = 0");
        gateway.payInvoice{ value: AMOUNT }(invoice, signature, address(0), "");
    }

    function test_revertFeeExceedsMax() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        invoice.feeBasisPoints = gateway.maxFeeBasisPoints() + 1;
        bytes memory signature = _sign(invoice);

        vm.prank(firstPayer);
        vm.expectRevert("feeBasisPoints > max");
        gateway.payInvoice{ value: AMOUNT }(invoice, signature, address(0), "");
    }

    function test_setMaxFeeBasisPoints() public {
        vm.prank(owner);
        gateway.setMaxFeeBasisPoints(500);
        assertEq(gateway.maxFeeBasisPoints(), 500);
    }

    function test_setMaxFee_RevertTooHigh() public {
        vm.prank(owner);
        vm.expectRevert("max > 100%");
        gateway.setMaxFeeBasisPoints(10_001);
    }

    function test_setMaxFee_RevertNotOwner() public {
        vm.prank(firstPayer);
        vm.expectRevert();
        gateway.setMaxFeeBasisPoints(500);
    }

    function test_signerRotationFullCycle() public {
        vm.prank(owner);
        gateway.scheduleInvoiceSignerUpdate(secondSigner);

        assertEq(gateway.pendingInvoiceSigner(), secondSigner);
        assertEq(gateway.invoiceSigner(), firstSigner);

        vm.expectRevert("timelock not elapsed");
        gateway.executeInvoiceSignerUpdate();

        vm.warp(block.timestamp + gateway.SIGNER_TIMELOCK());

        gateway.executeInvoiceSignerUpdate();

        assertEq(gateway.invoiceSigner(), secondSigner);
        assertEq(gateway.pendingInvoiceSigner(), address(0));
        assertEq(gateway.signerUpdateScheduledAt(), 0);

        // New signer works.
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes32 domainSeparator = gateway.domainSeparator();
        bytes32 structHash = gateway.invoiceStructHash(invoice);
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SECOND_SIGNER_KEY, digest);

        vm.prank(firstPayer);
        gateway.payInvoice{ value: AMOUNT }(
            invoice, abi.encodePacked(r, s, v), address(0), ""
        );
    }

    function test_signerRotationCancel() public {
        vm.prank(owner);
        gateway.scheduleInvoiceSignerUpdate(secondSigner);
        assertEq(gateway.pendingInvoiceSigner(), secondSigner);

        vm.prank(owner);
        gateway.cancelInvoiceSignerUpdate();

        assertEq(gateway.pendingInvoiceSigner(), address(0));
        assertEq(gateway.signerUpdateScheduledAt(), 0);
    }

    function test_signerRotation_RevertSame() public {
        vm.prank(owner);
        vm.expectRevert("same signer");
        gateway.scheduleInvoiceSignerUpdate(firstSigner);
    }

    function test_signerRotation_RevertZero() public {
        vm.prank(owner);
        vm.expectRevert("signer = 0");
        gateway.scheduleInvoiceSignerUpdate(address(0));
    }

    function test_executeUpdate_RevertNoPending() public {
        vm.expectRevert("no pending signer");
        gateway.executeInvoiceSignerUpdate();
    }

    function test_cancelUpdate_RevertNoPending() public {
        vm.prank(owner);
        vm.expectRevert("no pending signer");
        gateway.cancelInvoiceSignerUpdate();
    }

    function test_pauseUnpause() public {
        vm.prank(owner);
        gateway.pause();
        assertTrue(gateway.paused());

        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory signature = _sign(invoice);
        vm.prank(firstPayer);
        vm.expectRevert();
        gateway.payInvoice{ value: AMOUNT }(invoice, signature, address(0), "");

        vm.prank(owner);
        gateway.unpause();
        assertFalse(gateway.paused());

        vm.prank(firstPayer);
        gateway.payInvoice{ value: AMOUNT }(invoice, signature, address(0), "");
    }

    function test_pause_RevertNotOwner() public {
        vm.prank(firstPayer);
        vm.expectRevert();
        gateway.pause();
    }

    function test_rescueETH() public {
        vm.deal(address(gateway), 5 ether);
        assertEq(address(gateway).balance, 5 ether);

        vm.prank(owner);
        gateway.rescueETH(merchant, 5 ether);

        assertEq(merchant.balance, 5 ether);
        assertEq(address(gateway).balance, 0);
    }

    function test_rescueERC20() public {
        vm.prank(firstPayer);
        usdc.transfer(address(gateway), 1000);

        vm.prank(owner);
        gateway.rescueERC20(address(usdc), merchant, 1000);

        assertEq(usdc.balanceOf(merchant), 1000);
        assertEq(usdc.balanceOf(address(gateway)), 0);
    }

    function test_rescueETH_RevertNotOwner() public {
        vm.prank(firstPayer);
        vm.expectRevert();
        gateway.rescueETH(merchant, 0);
    }

    function test_rescueETH_RevertZero() public {
        vm.prank(owner);
        vm.expectRevert("to = 0");
        gateway.rescueETH(address(0), 0);
    }

    function test_ownershipTransfer() public {
        vm.prank(owner);
        gateway.transferOwnership(firstPayer);
        assertEq(gateway.owner(), owner);
        assertEq(gateway.pendingOwner(), firstPayer);

        vm.prank(firstPayer);
        gateway.acceptOwnership();
        assertEq(gateway.owner(), firstPayer);
        assertEq(gateway.pendingOwner(), address(0));
    }

    function test_receiveETH() public {
        vm.prank(firstPayer);
        (bool ok,) = address(gateway).call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(address(gateway).balance, 1 ether);
    }
}
