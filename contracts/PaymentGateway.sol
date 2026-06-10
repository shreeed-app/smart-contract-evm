// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title PaymentGateway
 * @notice Single-chain direct payments plus cross-chain bridge fulfillment.
 * Invoices are signed off-chain by an multi-party computation threshold engine
 * and verified on-chain via EIP-712.
 *
 * Path A — Direct payment:
 *   User calls payInvoice() with the invoice + multi-party computation
 *   signature. Funds flow from msg.sender to merchant + fee recipient in one
 *   atomic transaction.
 *
 * Path B — Bridge fulfillment:
 *   A bridge aggregator (Li.Fi, Across) delivers tokens to the contract
 *   then calls fulfillInvoice() with the invoice + multi-party computation
 *   signature. Funds flow from the contract's temporary balance — the bridge
 *   already deposited them earlier in the same transaction.
 *
 * Security:
 *   - Ownable2Step: two-step ownership transfer prevents accidental loss.
 *   - Signer rotation governed by a 48-hour timelock.
 *   - ReentrancyGuard + Pausable + EIP-712 dual-signature verification.
 *   - Rescue functions allow the owner to recover accidentally sent funds.
 */
contract PaymentGateway is Ownable2Step, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice Sentinel address identifying native ETH (as opposed to ERC20).
    address public constant NATIVE = address(0);

    /// @notice 48 hours in seconds — signer rotation timelock.
    uint256 public constant SIGNER_TIMELOCK = 48 hours;

    /// @notice Absolute cap on fee basis points (100%).
    uint16 public constant MAX_BPS = 10_000;

    /// @notice Maximum fee in basis points (e.g. 1_000 = 10%).
    uint16 public maxFeeBasisPoints = 1000;

    /// @notice The multi-party computation-derived public key address that
    /// signs invoices.
    address public invoiceSigner;

    /// @notice Pending invoice signer during rotation timelock.
    address public pendingInvoiceSigner;

    /// @notice Timestamp when the current rotation was scheduled.
    uint256 public signerUpdateScheduledAt;

    /// @notice Replay protection: one-time use per nonce.
    mapping(uint256 => bool) public usedNonces;

    /// @notice Invoice as signed by the multi-party computation engine (no
    /// payer field).
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

    bytes32 public constant INVOICE_TYPE_HASH = keccak256(
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

    bytes32 public constant PAYER_BIND_TYPE_HASH = keccak256(
        abi.encodePacked(
            "PayerBind(", "bytes32 invoiceHash,", "address payer", ")"
        )
    );

    /// @notice Emitted when an invoice is paid (both paths).
    event InvoicePaid(
        address indexed payer,
        address indexed merchant,
        address indexed token,
        uint256 amount,
        uint16 feeBasisPoints,
        address feeRecipient,
        bytes32 metadataHash,
        uint256 nonce
    );

    /// @notice Emitted when a signer rotation is scheduled.
    event SignerUpdateScheduled(
        address indexed currentSigner,
        address indexed newSigner,
        uint256 effectiveAt
    );

    /// @notice Emitted when a signer rotation is executed.
    event SignerUpdateExecuted(
        address indexed previousSigner, address indexed newSigner
    );

    /// @notice Emitted when a signer rotation is cancelled.
    event SignerUpdateCancelled(address indexed cancelledSigner);

    /**
     * @param _invoiceSigner The multi-party computation-derived address
     * authorized to sign invoices.
     * @param _owner The contract owner (multisig / governance).
     */
    constructor(address _invoiceSigner, address _owner)
        EIP712("PaymentGateway", "1")
        Ownable(_owner)
        Ownable2Step()
    {
        require(_invoiceSigner != address(0), "invoiceSigner = 0");
        invoiceSigner = _invoiceSigner;
    }

    /**
     * @notice Sets the maximum fee in basis points. Capped at MAX_BPS
     * (100%).
     * @param _maxFeeBasisPoints The new maximum fee basis points.
     */
    function setMaxFeeBasisPoints(uint16 _maxFeeBasisPoints)
        external
        onlyOwner
    {
        require(_maxFeeBasisPoints <= MAX_BPS, "max > 100%");
        maxFeeBasisPoints = _maxFeeBasisPoints;
    }

    /**
     * @notice Schedules a rotation of the invoice signer. The new signer
     * takes effect after SIGNER_TIMELOCK (48 hours). During the waiting
     * period the current signer remains valid.
     * @param _newSigner The address of the new invoice signer.
     */
    function scheduleInvoiceSignerUpdate(address _newSigner)
        external
        onlyOwner
    {
        require(_newSigner != address(0), "signer = 0");
        require(_newSigner != invoiceSigner, "same signer");
        pendingInvoiceSigner = _newSigner;
        signerUpdateScheduledAt = block.timestamp;
        emit SignerUpdateScheduled(
            invoiceSigner, _newSigner, block.timestamp + SIGNER_TIMELOCK
        );
    }

    /**
     * @notice Executes a previously scheduled signer rotation. Callable
     * by anyone once the timelock has elapsed.
     */
    function executeInvoiceSignerUpdate() external {
        require(pendingInvoiceSigner != address(0), "no pending signer");
        require(
            block.timestamp >= signerUpdateScheduledAt + SIGNER_TIMELOCK,
            "timelock not elapsed"
        );
        address previous = invoiceSigner;
        invoiceSigner = pendingInvoiceSigner;
        delete pendingInvoiceSigner;
        delete signerUpdateScheduledAt;
        emit SignerUpdateExecuted(previous, invoiceSigner);
    }

    /**
     * @notice Cancels a pending signer rotation. Only callable by the
     * owner.
     */
    function cancelInvoiceSignerUpdate() external onlyOwner {
        require(pendingInvoiceSigner != address(0), "no pending signer");
        address cancelled = pendingInvoiceSigner;
        delete pendingInvoiceSigner;
        delete signerUpdateScheduledAt;
        emit SignerUpdateCancelled(cancelled);
    }

    /**
     * @notice Pauses all payment processing (both paths).
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resumes all payment processing.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Recovers ETH accidentally sent directly to the contract
     * (not through payInvoice or fulfillInvoice).
     * @param to The destination address.
     * @param amount The amount to recover.
     */
    function rescueETH(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to = 0");
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "ETH transfer failed");
    }

    /**
     * @notice Recovers ERC20 tokens accidentally sent directly to the
     * contract.
     * @param token The token address.
     * @param to The destination address.
     * @param amount The amount to recover.
     */
    function rescueERC20(address token, address to, uint256 amount)
        external
        onlyOwner
    {
        require(to != address(0), "to = 0");
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Pays an invoice directly. The caller holds the funds and
     * approves the contract (for ERC20) or attaches msg.value (for ETH).
     *
     * @param invoice The backend-signed invoice.
     * @param backendSignature EIP-712 signature from the multi-party
     * computation engine.
     * @param payer Optional payer-lock address (0 = open to anyone).
     * @param payerSignature If payer != 0, EIP-712 PayerBind signature
     * by the payer authorizing them as the sole payer for this invoice.
     */
    function payInvoice(
        Invoice calldata invoice,
        bytes calldata backendSignature,
        address payer,
        bytes calldata payerSignature
    ) external payable nonReentrant whenNotPaused {
        _validateInvoice(invoice);
        _verifyInvoiceSignature(invoice, backendSignature);
        _verifyPayerLock(invoice, payer, payerSignature);
        _consumeNonce(invoice.nonce);

        if (invoice.token == NATIVE) {
            require(msg.value == invoice.amount, "wrong ETH amount");
            _splitETH(invoice);
        } else {
            // Pull tokens from payer.
            IERC20(invoice.token)
                .safeTransferFrom(msg.sender, address(this), invoice.amount);
            _splitERC20(invoice);
        }

        emit InvoicePaid(
            msg.sender,
            invoice.merchant,
            invoice.token,
            invoice.amount,
            invoice.feeBasisPoints,
            invoice.feeRecipient,
            invoice.metadataHash,
            invoice.nonce
        );
    }

    /**
     * @notice Fulfills an invoice from bridge-delivered funds. The bridge
     * aggregator (Li.Fi, Across) transfers tokens to this contract then
     * calls this function in the same atomic transaction.
     *
     * For ETH bridges: msg.value carries the bridged amount.
     * For ERC20 bridges: the tokens are already in the contract when
     * this function executes (the bridge transferred them first).
     *
     * Anyone can call this function — the invoice signature proves
     * authenticity, and the nonce prevents replay. The caller is
     * typically the bridge executor / relayer.
     *
     * @param invoice The backend-signed invoice.
     * @param backendSignature EIP-712 signature from the multi-party
     * computation engine.
     */
    function fulfillInvoice(
        Invoice calldata invoice,
        bytes calldata backendSignature
    ) external payable nonReentrant whenNotPaused {
        _validateInvoice(invoice);
        _verifyInvoiceSignature(invoice, backendSignature);

        // Bridge path: no payer-lock check — the bridge is the relayer,
        // and the invoice signature alone proves the backend authorised
        // this payment.
        _consumeNonce(invoice.nonce);

        if (invoice.token == NATIVE) {
            require(msg.value == invoice.amount, "wrong ETH amount");
            _splitETH(invoice);
        } else {
            // Tokens were already transferred to this contract by the
            // bridge in the same transaction before this call. The
            // safeTransfer below will revert if the balance is
            // insufficient, which rolls back the entire bridge tx.
            _splitERC20(invoice);
        }

        emit InvoicePaid(
            msg.sender,
            invoice.merchant,
            invoice.token,
            invoice.amount,
            invoice.feeBasisPoints,
            invoice.feeRecipient,
            invoice.metadataHash,
            invoice.nonce
        );
    }

    /**
     * @notice Returns the current EIP-712 domain separator.
     * @return The domain separator.
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Returns the EIP-712 struct hash for an invoice.
     * @param invoice The invoice to hash.
     * @return The struct hash.
     */
    function invoiceStructHash(Invoice calldata invoice)
        external
        pure
        returns (bytes32)
    {
        return _invoiceStructHash(invoice);
    }

    /**
     * @notice Returns the full EIP-712 digest for an invoice.
     * @param invoice The invoice to digest.
     * @return The EIP-712 digest.
     */
    function invoiceDigest(Invoice calldata invoice)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(_invoiceStructHash(invoice));
    }

    /**
     * @notice Returns the EIP-712 digest for a payer-bind message.
     * @param invoiceHash The invoice struct hash.
     * @param payer The payer address to bind.
     * @return The EIP-712 digest.
     */
    function payerBindDigest(bytes32 invoiceHash, address payer)
        external
        view
        returns (bytes32)
    {
        bytes32 bindHash = keccak256(
            abi.encode(PAYER_BIND_TYPE_HASH, invoiceHash, payer)
        );
        return _hashTypedDataV4(bindHash);
    }

    /**
     * @dev Validates the invoice invariants (non-signature fields).
     */
    function _validateInvoice(Invoice calldata invoice) internal view {
        require(invoice.merchant != address(0), "merchant = 0");
        require(invoice.feeRecipient != address(0), "feeRecipient = 0");
        require(invoice.amount > 0, "amount = 0");
        require(
            invoice.feeBasisPoints <= maxFeeBasisPoints, "feeBasisPoints > max"
        );
        require(block.timestamp <= invoice.expiry, "expired");
    }

    /**
     * @dev Verifies the multi-party computation EIP-712 signature on the
     * invoice.
     */
    function _verifyInvoiceSignature(
        Invoice calldata invoice,
        bytes calldata backendSignature
    ) internal view {
        bytes32 digest = _hashTypedDataV4(_invoiceStructHash(invoice));
        address recovered = ECDSA.recover(digest, backendSignature);
        require(recovered == invoiceSigner, "invalid invoice signature");
    }

    /**
     * @dev Verifies the optional payer-lock signature.
     */
    function _verifyPayerLock(
        Invoice calldata invoice,
        address payer,
        bytes calldata payerSignature
    ) internal view {
        if (payer == address(0)) return;

        require(msg.sender == payer, "unauthorized payer");
        bytes32 invoiceHash = _invoiceStructHash(invoice);
        bytes32 bindHash =
            keccak256(abi.encode(PAYER_BIND_TYPE_HASH, invoiceHash, payer));
        bytes32 bindDigest = _hashTypedDataV4(bindHash);
        address recovered = ECDSA.recover(bindDigest, payerSignature);
        require(recovered == payer, "invalid payer signature");
    }

    /**
     * @dev Consumes a nonce. Reverts if the nonce was already used.
     */
    function _consumeNonce(uint256 nonce) internal {
        require(!usedNonces[nonce], "nonce used");
        usedNonces[nonce] = true;
    }

    /**
     * @dev Computes the fee split and transfers ETH from the contract.
     */
    function _splitETH(Invoice calldata invoice) internal {
        (uint256 toMerchant, uint256 fee) =
            _computeSplit(invoice.amount, invoice.feeBasisPoints);
        _sendETH(invoice.merchant, toMerchant);
        if (fee > 0) _sendETH(invoice.feeRecipient, fee);
    }

    /**
     * @dev Computes the fee split and transfers ERC20 from the contract.
     */
    function _splitERC20(Invoice calldata invoice) internal {
        (uint256 toMerchant, uint256 fee) =
            _computeSplit(invoice.amount, invoice.feeBasisPoints);
        IERC20 token = IERC20(invoice.token);
        token.safeTransfer(invoice.merchant, toMerchant);
        if (fee > 0) token.safeTransfer(invoice.feeRecipient, fee);
    }

    /**
     * @dev Computes merchant and fee shares from gross amount.
     * @return toMerchant The merchant's share.
     * @return fee The platform fee.
     */
    function _computeSplit(uint256 amount, uint16 feeBasisPoints)
        internal
        pure
        returns (uint256 toMerchant, uint256 fee)
    {
        fee = (amount * feeBasisPoints) / MAX_BPS;
        toMerchant = amount - fee;
        require(toMerchant > 0, "split = 0");
    }

    /**
     * @dev Computes the EIP-712 struct hash for an Invoice.
     */
    function _invoiceStructHash(Invoice calldata invoice)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
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
     * @dev Low-level ETH transfer. Uses call{} with no gas limit (modern
     * best practice, avoids the 2300-gas stipend limitation).
     */
    function _sendETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "ETH transfer failed");
    }

    /**
     * @notice Accepts incoming ETH transfers (bridge deposits, tips).
     * No logic — funds are held until fulfillInvoice or rescue.
     */
    receive() external payable { }
}
