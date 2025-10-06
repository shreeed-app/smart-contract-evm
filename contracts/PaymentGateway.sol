// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PaymentGateway is Ownable, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;

    address public constant NATIVE = address(0);

    uint16 public maxFeeBasisPoints = 1_000; // 10%
    address public invoiceSigner; // Backend signer public key.

    mapping(uint256 => bool) public usedNonces;

    // Invoice struct as signed by backend (no payer).
    struct Invoice {
        address merchant;
        address token;
        uint256 amount;
        uint16 feeBasisPoints;
        address feeRecipient;
        uint256 expiry;
        uint256 nonce;
        bytes32 metadataHash;
    }

    // Emitted after successful payment.
    // Includes payer for reference.
    struct _PaidInvoice {
        address payer;
        address merchant;
        address token;
        uint256 amount;
        uint16 feeBasisPoints;
        address feeRecipient;
        bytes32 metadataHash;
        uint256 nonce;
    }

    // Invoice struct as signed by backend (no payer).
    bytes32 public constant INVOICE_TYPE_HASH =
        keccak256(
            abi.encodePacked(
                "Invoice(",
                "address merchant,",
                "address token,",
                "uint256 amount,",
                "uint16 feeBasisPoints,",
                "address feeRecipient,",
                "uint256 expiry,",
                "uint256 nonce,",
                "bytes32 metadataHash",
                ")"
            )
        );

    // Payer bind struct: binds an invoice to a specific payer address.
    bytes32 public constant PAYER_BIND_TYPE_HASH =
        keccak256(
            abi.encodePacked(
                "PayerBind(",
                "bytes32 invoiceHash,",
                "address payer",
                ")"
            )
        );

    event PaidInvoice(_PaidInvoice invoice);

    /**
     * @dev Constructor.
     * @param _invoiceSigner The address authorized to sign invoices.
     * @param _owner The owner of the contract (can change settings).
     */
    constructor(
        address _invoiceSigner,
        address _owner
    ) EIP712("PaymentGateway", "1") Ownable(_owner) {
        require(_invoiceSigner != address(0), "invoiceSigner = 0");
        invoiceSigner = _invoiceSigner;
    }

    /**
     * @dev Set the maximum fee basis points (max 10000 = 100%).
     * @param feeBasisPoints The new maximum fee basis points.
     */
    function setMaxFeeBasisPoints(uint16 feeBasisPoints) external onlyOwner {
        require(feeBasisPoints <= 10_000, "max > 100%");
        maxFeeBasisPoints = feeBasisPoints;
    }

    /**
     * @dev Set the invoice signer address.
     * @param _invoiceSigner The new invoice signer address.
     */
    function setInvoiceSigner(address _invoiceSigner) external onlyOwner {
        require(_invoiceSigner != address(0), "invoiceSigner = 0");
        invoiceSigner = _invoiceSigner;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @param invoice Backend-signed invoice (no payer in struct)
     * @param backendSignature Signature from invoiceSigner.
     * @param payer Optional lock: 0 = open, else must equal msg.sender.
     * @param payerSignature If payer != 0, EIP-712 signature by payer.
     */
    function payInvoice(
        Invoice calldata invoice,
        bytes calldata backendSignature,
        address payer,
        bytes calldata payerSignature
    ) external payable nonReentrant whenNotPaused {
        require(invoice.merchant != address(0), "merchant = 0");
        require(invoice.feeRecipient != address(0), "feeRecipient = 0");
        require(invoice.amount > 0, "amount = 0");
        require(
            invoice.feeBasisPoints <= maxFeeBasisPoints,
            "feeBasisPoints > max"
        );
        require(block.timestamp <= invoice.expiry, "expired");
        require(!usedNonces[invoice.nonce], "nonce already used");

        // Verify backend signature.
        bytes32 invoiceHash = _invoiceStructHash(invoice);
        bytes32 invoiceDigest = _hashTypedDataV4(invoiceHash);
        address recovered = ECDSA.recover(invoiceDigest, backendSignature);
        require(recovered == invoiceSigner, "incorrect backend signature");

        // Optional payer lock.
        if (payer != address(0)) {
            require(msg.sender == payer, "unauthorized payer");
            // Verify payer bind signature.
            bytes32 bindHash = keccak256(
                abi.encode(PAYER_BIND_TYPE_HASH, invoiceHash, payer)
            );
            bytes32 bindDigest = _hashTypedDataV4(bindHash);
            address _payer = ECDSA.recover(bindDigest, payerSignature);
            require(_payer == payer, "incorrect payer signature");
        }

        usedNonces[invoice.nonce] = true;

        // Split payment.
        uint256 fee = (invoice.amount * invoice.feeBasisPoints) / 10_000;
        uint256 toMerchant = invoice.amount - fee;
        require(toMerchant > 0, "split = 0");

        if (invoice.token == NATIVE) {
            require(msg.value == invoice.amount, "wrong ETH amount");
            _sendETH(invoice.merchant, toMerchant);
            if (fee > 0) _sendETH(invoice.feeRecipient, fee);
        } else {
            IERC20 transfer = IERC20(invoice.token);
            transfer.safeTransferFrom(
                msg.sender,
                address(this),
                invoice.amount
            );
            if (toMerchant > 0) {
                // Send amount to merchant.
                transfer.safeTransfer(invoice.merchant, toMerchant);
            }
            if (fee > 0) {
                // Send fee to feeRecipient.
                transfer.safeTransfer(invoice.feeRecipient, fee);
            }
        }

        emit PaidInvoice(
            _PaidInvoice(
                msg.sender,
                invoice.merchant,
                invoice.token,
                invoice.amount,
                invoice.feeBasisPoints,
                invoice.feeRecipient,
                invoice.metadataHash,
                invoice.nonce
            )
        );
    }

    /**
     * @dev Compute the struct hash for an Invoice.
     * @param invoice The invoice struct to hash.
     * @return The computed struct hash as a bytes32 value.
     */
    function _invoiceStructHash(
        Invoice calldata invoice
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    INVOICE_TYPE_HASH,
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

    /**
     * @dev Internal function to send ETH and handle failures.
     * @param to Recipient address.
     * @param amount Amount of ETH to send.
     */
    function _sendETH(address to, uint256 amount) internal {
        (bool ok, ) = to.call{ value: amount }("");
        require(ok, "ETH transfer failed");
    }
}
