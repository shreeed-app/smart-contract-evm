// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./PaymentGateway.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PaymentGatewayTest is Test {
    uint256 private constant OWNER_KEY = 0xA11CE;
    uint256 private constant PAYER_KEY = 0xB0B;
    uint256 private constant PAYER2_KEY = 0xB0B2;
    uint256 private constant MERCHANT_KEY = 0xC0DE;
    uint256 private constant SIGNER_KEY = 0xD00D;
    uint256 private constant SIGNER2_KEY = 0xD00D2;
    uint256 private constant FEE_KEY = 0xFEE;
    uint256 private constant RELAYER_KEY = 0x5AFE;

    address private owner;
    address private payer;
    address private payer2;
    address private merchant;
    address private signer;
    address private signer2;
    address private feeRecipient;
    address private relayer;

    PaymentGateway private gateway;
    MockUSDC private usdc;

    uint16 private constant FEES = 1_000;
    uint256 private constant AMOUNT = 1 ether;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        payer = vm.addr(PAYER_KEY);
        payer2 = vm.addr(PAYER2_KEY);
        merchant = vm.addr(MERCHANT_KEY);
        signer = vm.addr(SIGNER_KEY);
        signer2 = vm.addr(SIGNER2_KEY);
        feeRecipient = vm.addr(FEE_KEY);
        relayer = vm.addr(RELAYER_KEY);

        vm.deal(payer, 100 ether);
        vm.deal(payer2, 100 ether);
        vm.deal(owner, 100 ether);
        vm.deal(relayer, 100 ether);

        usdc = new MockUSDC();

        vm.prank(owner);
        gateway = new PaymentGateway(signer, owner);

        usdc.mint(payer, 1_000_000 * 1e18);
        usdc.mint(payer2, 1_000_000 * 1e18);
        usdc.mint(relayer, 1_000_000 * 1e18);
        vm.prank(payer);
        usdc.approve(address(gateway), type(uint256).max);
        vm.prank(payer2);
        usdc.approve(address(gateway), type(uint256).max);
        vm.prank(relayer);
        usdc.approve(address(gateway), type(uint256).max);
    }

    function _invoice(address token)
        internal view returns (PaymentGateway.Invoice memory)
    {
        return PaymentGateway.Invoice({
            merchant: merchant,
            token: token,
            amount: AMOUNT,
            feeBasisPoints: FEES,
            feeRecipient: feeRecipient,
            expiry: block.timestamp + 1 hours,
            nonce: uint256(keccak256(abi.encodePacked(block.timestamp, gasleft()))),
            metadataHash: keccak256("test")
        });
    }

    function _sign(PaymentGateway.Invoice memory invoice)
        internal view returns (bytes memory)
    {
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            gateway.domainSeparator(),
            gateway.invoiceStructHash(invoice)
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signPayerBind(
        PaymentGateway.Invoice memory invoice,
        address payerAddr
    ) internal view returns (bytes memory) {
        bytes32 invoiceHash = gateway.invoiceStructHash(invoice);
        bytes32 bindStructHash = keccak256(abi.encode(
            gateway.PAYER_BIND_TYPE_HASH(), invoiceHash, payerAddr
        ));
        bytes32 bindDigest = keccak256(abi.encodePacked(
            "\x19\x01", gateway.domainSeparator(), bindStructHash
        ));
        uint256 key = payerAddr == payer ? PAYER_KEY : PAYER2_KEY;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, bindDigest);
        return abi.encodePacked(r, s, v);
    }

    function _split(uint256 amount, uint16 bps)
        internal pure returns (uint256 toMerchant, uint256 fee)
    {
        fee = (amount * bps) / 10_000;
        toMerchant = amount - fee;
    }

    // ── Deployment ────────────────────────────────────────

    function test_deploymentState() public view {
        assertEq(gateway.invoiceSigner(), signer);
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
        new PaymentGateway(signer, address(0));
    }

    // ── Path A: Direct ETH ────────────────────────────────

    function test_payInvoiceETH() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory backendSig = _sign(invoice);
        bytes memory payerSig = _signPayerBind(invoice, payer);

        uint256 mb = merchant.balance;
        uint256 fb = feeRecipient.balance;

        vm.expectEmit(true, true, true, true, address(gateway));
        emit PaymentGateway.InvoicePaid(
            payer, invoice.merchant, gateway.NATIVE(),
            invoice.amount, invoice.feeBasisPoints, invoice.feeRecipient,
            invoice.metadataHash, invoice.nonce
        );

        vm.prank(payer);
        gateway.payInvoice{ value: AMOUNT }(
            invoice, backendSig, payer, payerSig
        );

        (uint256 toMerchant, uint256 fee) = _split(AMOUNT, FEES);
        assertEq(merchant.balance - mb, toMerchant);
        assertEq(feeRecipient.balance - fb, fee);
        assertEq(address(gateway).balance, 0);
        assertTrue(gateway.usedNonces(invoice.nonce));
    }

    function test_payInvoiceETH_Open() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory sig = _sign(invoice);

        vm.prank(payer2);
        gateway.payInvoice{ value: AMOUNT }(invoice, sig, address(0), "");

        (uint256 toMerchant,) = _split(AMOUNT, FEES);
        assertEq(merchant.balance, toMerchant);
        assertTrue(gateway.usedNonces(invoice.nonce));
    }

    function test_payInvoiceETH_WrongValue() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory sig = _sign(invoice);

        vm.prank(payer);
        vm.expectRevert("wrong ETH amount");
        gateway.payInvoice{ value: AMOUNT - 1 }(invoice, sig, address(0), "");
    }

    // ── Path A: Direct ERC20 ─────────────────────────────

    function test_payInvoiceERC20() public {
        PaymentGateway.Invoice memory invoice = _invoice(address(usdc));
        bytes memory backendSig = _sign(invoice);
        bytes memory payerSig = _signPayerBind(invoice, payer);

        (uint256 toMerchant, uint256 fee) = _split(AMOUNT, FEES);

        vm.prank(payer);
        gateway.payInvoice(invoice, backendSig, payer, payerSig);

        assertEq(usdc.balanceOf(merchant), toMerchant);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(address(gateway)), 0);
    }

    // ── Path A: payer lock ────────────────────────────────

    function test_payInvoice_RevertUnauthorized() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory backendSig = _sign(invoice);
        bytes memory payerSig = _signPayerBind(invoice, payer);

        vm.prank(payer2);
        vm.expectRevert("unauthorized payer");
        gateway.payInvoice{ value: AMOUNT }(
            invoice, backendSig, payer, payerSig
        );
    }

    function test_payInvoice_RevertBadPayerSig() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory backendSig = _sign(invoice);
        bytes memory payerSig = _signPayerBind(invoice, payer2);

        vm.prank(payer);
        vm.expectRevert("invalid payer sig");
        gateway.payInvoice{ value: AMOUNT }(
            invoice, backendSig, payer, payerSig
        );
    }

    // ── Path B: Bridge ETH ────────────────────────────────

    function test_fulfillInvoiceETH() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory sig = _sign(invoice);

        uint256 mb = merchant.balance;
        uint256 fb = feeRecipient.balance;

        vm.expectEmit(true, true, true, true, address(gateway));
        emit PaymentGateway.InvoicePaid(
            relayer, invoice.merchant, gateway.NATIVE(),
            invoice.amount, invoice.feeBasisPoints, invoice.feeRecipient,
            invoice.metadataHash, invoice.nonce
        );

        vm.prank(relayer);
        gateway.fulfillInvoice{ value: AMOUNT }(invoice, sig);

        (uint256 toMerchant, uint256 fee) = _split(AMOUNT, FEES);
        assertEq(merchant.balance - mb, toMerchant);
        assertEq(feeRecipient.balance - fb, fee);
        assertEq(address(gateway).balance, 0);
        assertTrue(gateway.usedNonces(invoice.nonce));
    }

    function test_fulfillInvoiceETH_WrongValue() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory sig = _sign(invoice);

        vm.prank(relayer);
        vm.expectRevert("wrong ETH amount");
        gateway.fulfillInvoice{ value: AMOUNT - 1 }(invoice, sig);
    }

    // ── Path B: Bridge ERC20 ──────────────────────────────

    function test_fulfillInvoiceERC20() public {
        vm.prank(relayer);
        usdc.transfer(address(gateway), AMOUNT);
        assertEq(usdc.balanceOf(address(gateway)), AMOUNT);

        PaymentGateway.Invoice memory invoice = _invoice(address(usdc));
        bytes memory sig = _sign(invoice);

        vm.prank(relayer);
        gateway.fulfillInvoice(invoice, sig);

        (uint256 toMerchant, uint256 fee) = _split(AMOUNT, FEES);
        assertEq(usdc.balanceOf(merchant), toMerchant);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(address(gateway)), 0);
        assertTrue(gateway.usedNonces(invoice.nonce));
    }

    // ── Edge cases ────────────────────────────────────────

    function test_revertExpired() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        invoice.expiry = block.timestamp - 1;
        bytes memory sig = _sign(invoice);

        vm.prank(payer);
        vm.expectRevert("expired");
        gateway.payInvoice{ value: AMOUNT }(invoice, sig, address(0), "");
    }

    function test_revertNonceReused() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory sig = _sign(invoice);

        vm.prank(payer);
        gateway.payInvoice{ value: AMOUNT }(invoice, sig, address(0), "");

        vm.prank(payer2);
        vm.expectRevert("nonce used");
        gateway.payInvoice{ value: AMOUNT }(invoice, sig, address(0), "");
    }

    function test_revertBadInvoiceSig() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            gateway.domainSeparator(),
            gateway.invoiceStructHash(invoice)
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(payer);
        vm.expectRevert("invalid invoice sig");
        gateway.payInvoice{ value: AMOUNT }(invoice, badSig, address(0), "");
    }

    function test_revertZeroMerchant() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        invoice.merchant = address(0);
        bytes memory sig = _sign(invoice);

        vm.prank(payer);
        vm.expectRevert("merchant = 0");
        gateway.payInvoice{ value: AMOUNT }(invoice, sig, address(0), "");
    }

    function test_revertZeroFeeRecipient() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        invoice.feeRecipient = address(0);
        bytes memory sig = _sign(invoice);

        vm.prank(payer);
        vm.expectRevert("feeRecipient = 0");
        gateway.payInvoice{ value: AMOUNT }(invoice, sig, address(0), "");
    }

    function test_revertFeeExceedsMax() public {
        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        invoice.feeBasisPoints = gateway.maxFeeBasisPoints() + 1;
        bytes memory sig = _sign(invoice);

        vm.prank(payer);
        vm.expectRevert("feeBasisPoints > max");
        gateway.payInvoice{ value: AMOUNT }(invoice, sig, address(0), "");
    }

    // ── Admin: fee cap ────────────────────────────────────

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
        vm.prank(payer);
        vm.expectRevert();
        gateway.setMaxFeeBasisPoints(500);
    }

    // ── Admin: timelocked signer rotation ─────────────────

    function test_signerRotationFullCycle() public {
        vm.prank(owner);
        gateway.scheduleInvoiceSignerUpdate(signer2);

        assertEq(gateway.pendingInvoiceSigner(), signer2);
        assertEq(gateway.invoiceSigner(), signer);

        vm.expectRevert("timelock not elapsed");
        gateway.executeInvoiceSignerUpdate();

        vm.warp(block.timestamp + gateway.SIGNER_TIMELOCK());

        gateway.executeInvoiceSignerUpdate();

        assertEq(gateway.invoiceSigner(), signer2);
        assertEq(gateway.pendingInvoiceSigner(), address(0));
        assertEq(gateway.signerUpdateScheduledAt(), 0);

        // New signer works.
        PaymentGateway.Invoice memory inv = _invoice(gateway.NATIVE());
        bytes32 ds = gateway.domainSeparator();
        bytes32 sh = gateway.invoiceStructHash(inv);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER2_KEY, digest);

        vm.prank(payer);
        gateway.payInvoice{ value: AMOUNT }(
            inv, abi.encodePacked(r, s, v), address(0), ""
        );
    }

    function test_signerRotationCancel() public {
        vm.prank(owner);
        gateway.scheduleInvoiceSignerUpdate(signer2);
        assertEq(gateway.pendingInvoiceSigner(), signer2);

        vm.prank(owner);
        gateway.cancelInvoiceSignerUpdate();

        assertEq(gateway.pendingInvoiceSigner(), address(0));
        assertEq(gateway.signerUpdateScheduledAt(), 0);
    }

    function test_signerRotation_RevertSame() public {
        vm.prank(owner);
        vm.expectRevert("same signer");
        gateway.scheduleInvoiceSignerUpdate(signer);
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

    // ── Pause / unpause ──────────────────────────────────

    function test_pauseUnpause() public {
        vm.prank(owner);
        gateway.pause();
        assertTrue(gateway.paused());

        PaymentGateway.Invoice memory invoice = _invoice(gateway.NATIVE());
        bytes memory sig = _sign(invoice);
        vm.prank(payer);
        vm.expectRevert();
        gateway.payInvoice{ value: AMOUNT }(invoice, sig, address(0), "");

        vm.prank(owner);
        gateway.unpause();
        assertFalse(gateway.paused());

        vm.prank(payer);
        gateway.payInvoice{ value: AMOUNT }(invoice, sig, address(0), "");
    }

    function test_pause_RevertNotOwner() public {
        vm.prank(payer);
        vm.expectRevert();
        gateway.pause();
    }

    // ── Rescue ────────────────────────────────────────────

    function test_rescueETH() public {
        vm.deal(address(gateway), 5 ether);
        assertEq(address(gateway).balance, 5 ether);

        vm.prank(owner);
        gateway.rescueETH(merchant, 5 ether);

        assertEq(merchant.balance, 5 ether);
        assertEq(address(gateway).balance, 0);
    }

    function test_rescueERC20() public {
        vm.prank(payer);
        usdc.transfer(address(gateway), 1000);

        vm.prank(owner);
        gateway.rescueERC20(address(usdc), merchant, 1000);

        assertEq(usdc.balanceOf(merchant), 1000);
        assertEq(usdc.balanceOf(address(gateway)), 0);
    }

    function test_rescueETH_RevertNotOwner() public {
        vm.prank(payer);
        vm.expectRevert();
        gateway.rescueETH(merchant, 0);
    }

    function test_rescueETH_RevertZero() public {
        vm.prank(owner);
        vm.expectRevert("to = 0");
        gateway.rescueETH(address(0), 0);
    }

    // ── Ownable2Step ──────────────────────────────────────

    function test_ownershipTransfer() public {
        vm.prank(owner);
        gateway.transferOwnership(payer);
        assertEq(gateway.owner(), owner);
        assertEq(gateway.pendingOwner(), payer);

        vm.prank(payer);
        gateway.acceptOwnership();
        assertEq(gateway.owner(), payer);
        assertEq(gateway.pendingOwner(), address(0));
    }

    // ── Receive ───────────────────────────────────────────

    function test_receiveETH() public {
        vm.prank(payer);
        (bool ok,) = address(gateway).call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(address(gateway).balance, 1 ether);
    }
}
