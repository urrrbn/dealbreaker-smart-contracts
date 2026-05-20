// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IEscrow {
    // =====================================================================
    // Enums
    // =====================================================================

    /// @notice Escrow lifecycle state.
    /// @dev Transitions:
    //      AwaitingAcceptance -> Active     // founder + investor signatures activate the escrow
    //      Active -> Finalized              // every milestone has been released or resolved
    //      AwaitingAcceptance -> Cancelled  // escrow is cancelled before activation
    //      Active -> Cancelled              // escrow is cancelled by consent or refund drain
    enum EscrowState {
        AwaitingAcceptance,
        Active,
        Finalized,
        Cancelled
    }

    /// @notice Per-milestone state machine.
    /// @dev Transitions:
    //      Pending -> Active       // milestone becomes current
    //      Active -> Funded        // investor deposits the required amount
    //      Funded -> Verified      // investor approves delivery
    //      Verified -> Released    // founder receives funds
    //      Funded -> Refundable    // deadline + grace expires, or investor wins dispute
    //      Refundable -> Refunded  // investor claims refund
    //      Active -> Refunded      // escrow is cancelled before funding
    enum MilestoneState {
        Pending,
        Active,
        Funded,
        Verified,
        Released,
        Refunded,
        Refundable
    }

    // =====================================================================
    // Structs
    // =====================================================================

    /// @notice Stored milestone terms and current state.
    struct Milestone {
        uint256 amount; // declared target amount
        uint64 deadline; // verification deadline, as a UNIX timestamp
        uint8 state; // MilestoneState
        bytes32 descriptionHash; // keccak256 of off-chain description document
    }

    /// @notice Active dispute data for a milestone.
    /// @dev Non-zero `openedAt` means the dispute is active. While active, this overlay blocks
    ///      milestone actions without changing the milestone's base state. Clear it after
    ///      ruling or expiry.
    struct DisputeInfo {
        uint64 openedAt; // block.timestamp at createDispute (zero = no active dispute)
        uint64 endsAt; // openedAt + DISPUTE_WINDOW
        uint64 graceRemaining; // grace seconds snapshotted at createDispute
        uint8 priorState; // milestone state snapshotted at createDispute
        address initiator; // msg.sender at createDispute
        bytes32 evidenceHash; // keccak256 of the off-chain evidence bundle
    }

    /// @notice Return struct for `getEscrowSummary()`. Not a storage struct.
    struct EscrowSummary {
        bytes32 escrowId;
        address founder;
        address token;
        uint256 totalAmount;
        uint256 totalReleased;
        uint256 totalAccounted;
        uint256 milestoneCount;
        uint256 currentMilestoneIndex;
        EscrowState escrowState;
        uint16 feeBps;
        uint32 gracePeriod;
        uint16 quorumBps;
    }

    /// @notice Initialization payload for factory-driven clone init.
    /// @dev Kept as a struct to survive stack-depth limits and to document the full
    ///      freeze-locked init surface in one place.
    struct InitParams {
        bytes32 escrowId;
        address factory; // msg.sender at init time; the only authorized initializer
        address founder;
        address token; // USDC on Base in v0; factory validates allowlist
        address investor;
        uint256[] milestoneAmounts; // declared milestone targets (sums equal totalAmount)
        uint64[] milestoneDeadlines; // UNIX timestamps
        bytes32[] milestoneDescriptionHashes;
        uint16 feeBps; // basis points, e.g. 500 = 5%
        uint32 gracePeriod; // seconds after deadline before refunds unlock
        uint16 quorumBps; // basis points threshold, e.g. 5_001 for ">50%"
        address arbitrator; // dispute arbitrator snapshotted at init
    }

    // =====================================================================
    // Events
    // =====================================================================

    /// @notice Emitted exactly once at clone initialization.
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed founder,
        address indexed token,
        uint256 totalAmount,
        uint256 milestones
    );

    /// @notice Emitted when founder and investor `EscrowAcceptance` signatures activate the escrow.
    event EscrowActivated(bytes32 indexed escrowId, uint64 activatedAt);

    /// @notice Emitted on investor deposit into a milestone.
    event MilestoneDeposited(uint256 indexed milestoneIndex, address indexed investor, uint256 amount, uint256 feePaid);

    /// @notice Emitted when signature-weighted verification passes for a milestone.
    event MilestoneVerified(uint256 indexed milestoneIndex, uint256 weight, uint256 threshold, bytes32 evidenceHash);

    /// @notice Emitted when verified funds are released to the founder, net of fee.
    event MilestoneReleased(
        uint256 indexed milestoneIndex, address indexed founder, uint256 amountToFounder, uint256 feeAmount
    );

    /// @notice Emitted when an investor pulls a refund after grace expiry.
    event MilestoneRefunded(uint256 indexed milestoneIndex, address indexed investor, uint256 amount);

    /// @notice Emitted when mutual consent rewrites milestone terms.
    event MilestoneRenegotiated(
        uint256 indexed milestoneIndex, uint64 newDeadline, uint256 newAmount, bytes32 newDescriptionHash
    );

    /// @notice Emitted when the platform fee is sent to the treasury.
    event FeeCollected(uint256 indexed milestoneIndex, address indexed treasury, uint256 amount);

    /// @notice Emitted when the escrow is cancelled by consent or refund drain.
    event EscrowCancelled(bytes32 indexed escrowId, uint64 cancelledAt);

    /// @notice Emitted when a dispute is opened on a milestone.
    /// @param milestoneIndex Milestone being disputed.
    /// @param initiator `msg.sender` at `createDispute` (founder or a depositing investor).
    /// @param evidenceHash keccak256 of the off-chain evidence bundle committed on-chain.
    /// @param endsAt UNIX timestamp at which the dispute window elapses (openedAt + DISPUTE_WINDOW).
    event DisputeCreated(
        uint256 indexed milestoneIndex, address indexed initiator, bytes32 evidenceHash, uint64 endsAt
    );

    /// @notice Emitted alongside `Ruling` when the arbitrator force-verifies a milestone.
    /// @dev Distinct from `MilestoneVerified`: force-release bypasses the signature path.
    /// @param milestoneIndex Milestone that was force-verified and released.
    /// @param arbitrator The per-clone arbitrator that issued the ruling.
    /// @param toFounder Net amount transferred to the founder.
    /// @param toTreasury Fee amount transferred to the treasury, rounded down.
    event MilestoneForceReleased(
        uint256 indexed milestoneIndex, address indexed arbitrator, uint256 toFounder, uint256 toTreasury
    );

    /// @notice Emitted when a dispute expires without a ruling.
    /// @param milestoneIndex Milestone whose dispute expired.
    /// @param priorState Base milestone state at the time the dispute was opened (restored on expiry).
    event DisputeExpired(uint256 indexed milestoneIndex, uint8 priorState);

    /// @notice Emitted when grace resumes after dispute resolution.
    /// @param milestoneIndex Milestone whose grace timer has resumed.
    /// @param newGraceEndsAt New `graceEndsAt` timestamp (now + graceRemaining, clamped).
    event DisputeGraceResumed(uint256 indexed milestoneIndex, uint64 newGraceEndsAt);

    // =====================================================================
    // Lifecycle - initialization
    // =====================================================================

    /// @notice Initialize the clone with frozen escrow parameters.
    /// @dev Can only be called once, and only by the factory that cloned this contract.
    /// @param params Packed initialization struct; see `InitParams`.
    function initialize(InitParams calldata params) external;

    // =====================================================================
    // Lifecycle - escrow activation (EIP-712)
    // =====================================================================

    /// @notice Submit founder + investor signatures and activate the escrow.
    /// @dev The order of `signatures` must be [founder, investor]. Each signer nonce is
    ///      consumed atomically. On success, escrow state becomes `Active` and milestone 0
    ///      becomes `Active`.
    /// @param signatures Ordered 65-byte EIP-712 signatures over `EscrowAcceptance`.
    /// @param acceptanceDeadline UNIX timestamp after which the signed payload is invalid.
    function activateEscrow(bytes[] calldata signatures, uint256 acceptanceDeadline) external;

    // =====================================================================
    // Lifecycle - per-milestone flow
    // =====================================================================

    /// @notice Deposit the investor tranche for the current milestone.
    /// @param milestoneIndex Milestone receiving funds. Must equal the current milestone.
    function deposit(uint256 milestoneIndex) external;

    /// @notice Submit investor EIP-712 verification and release the milestone on success.
    /// @dev Passes only when distinct signer weight reaches the configured quorum threshold.
    /// @param milestoneIndex Milestone being verified.
    /// @param evidenceHash keccak256 of the off-chain evidence bundle.
    /// @param signers Signers whose verification signatures are submitted.
    /// @param signatures EIP-712 signatures aligned index-for-index with `signers`.
    /// @param verificationDeadline UNIX timestamp after which the signed payload is invalid.
    function verifyMilestone(
        uint256 milestoneIndex,
        bytes32 evidenceHash,
        address[] calldata signers,
        bytes[] calldata signatures,
        uint256 verificationDeadline
    ) external;

    /// @notice Rewrite milestone terms with founder + investor consent.
    /// @dev Only callable while the milestone is inside its grace window and has not been
    ///      released or fully refunded. On success, milestone transitions to a fresh `Funded`
    ///      state with the new deadline and amount.
    /// @param milestoneIndex Milestone to renegotiate.
    /// @param newDeadline New verification deadline. Must be strictly in the future.
    /// @param newAmount New target amount. Existing deposits are reconciled against the new amount.
    /// @param newDescriptionHash keccak256 of the revised milestone document.
    /// @param signers Founder followed by the depositing investor for this milestone.
    /// @param signatures EIP-712 signatures aligned with `signers`.
    /// @param renegDeadline UNIX timestamp after which the signed payload is invalid.
    function renegotiateMilestone(
        uint256 milestoneIndex,
        uint64 newDeadline,
        uint256 newAmount,
        bytes32 newDescriptionHash,
        address[] calldata signers,
        bytes[] calldata signatures,
        uint256 renegDeadline
    ) external;

    /// @notice Pull a refund after grace expires without verification.
    /// @param milestoneIndex Milestone whose grace period has expired.
    function claimRefund(uint256 milestoneIndex) external;

    // =====================================================================
    // Dispute arbitration - ERC-792 compatible
    // =====================================================================
    //
    // `rule(uint256,uint256)` is inherited from `IArbitrable` by the concrete escrow and is
    // not redeclared here. Solidity rejects duplicate declarations for the same function.

    /// @notice Open a dispute on a milestone.
    /// @dev Callable by the founder or the depositing investor. Commits evidence and starts
    ///      `DISPUTE_WINDOW`. While active, the dispute blocks verification, release, refund,
    ///      renegotiation, and cancellation for this milestone.
    /// @param milestoneIndex Milestone being disputed. Must be active or funded, past its
    ///                       deadline, and still inside grace.
    /// @param evidenceHash keccak256 of the off-chain evidence bundle. Must be non-zero.
    function createDispute(uint256 milestoneIndex, bytes32 evidenceHash) external;

    /// @notice Close an expired dispute with no ruling.
    /// @dev Permissionless after `DISPUTE_WINDOW`. Moves the milestone to `Refundable` and
    ///      resumes grace from the snapshotted `graceRemaining`.
    /// @param milestoneIndex Milestone whose dispute window has elapsed.
    function resolveExpiredDispute(uint256 milestoneIndex) external;

    // =====================================================================
    // Views
    // =====================================================================

    /// @notice Return a compact summary of the escrow's current state.
    /// @return summary Current escrow summary.
    function getEscrowSummary() external view returns (EscrowSummary memory summary);

    /// @notice Return the full milestone record for the given index.
    /// @param milestoneIndex Milestone index.
    /// @return milestone The stored `Milestone` struct.
    function getMilestone(uint256 milestoneIndex) external view returns (Milestone memory milestone);

    /// @notice Return the dispute overlay for a milestone.
    /// @dev Returns a zeroed struct when no dispute is active for `milestoneIndex`.
    /// @param milestoneIndex Milestone index.
    /// @return info The stored `DisputeInfo` struct.
    function getDisputeInfo(uint256 milestoneIndex) external view returns (DisputeInfo memory info);

    /// @notice Return the current EIP-712 nonce for a signer.
    /// @param signer Address whose nonce is being queried.
    /// @return nonce The next nonce expected from `signer`.
    function nonceOf(address signer) external view returns (uint256 nonce);

    /// @notice EIP-712 domain separator bound to this clone and the current chain.
    /// @return separator The domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32 separator);

    /// @notice Factory that deployed this clone.
    /// @return factoryAddress The factory address.
    function factory() external view returns (address factoryAddress);

    /// @notice Settlement token.
    /// @return tokenAddress The ERC20 token this escrow holds.
    function token() external view returns (address tokenAddress);
}
