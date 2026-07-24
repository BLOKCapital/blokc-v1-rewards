//SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/*###############################################################################

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BLOKCContributorFactory} from "./factory/BLOKCContributorFactory.sol";

/// @title  BLOKCDistributor
/// @author BLOK Capital DAO
/// @notice AI-proposed, all-signers-must-approve weekly reward distribution for
///         contributor accounts. The AI proposer submits a batch of
///         (contributor, amount) pairs; after ALL designated signers
///         approve, anyone can execute the distribution, which transfers
///         $BLOKC to each contributor's deterministic account address.
///
///         The contract acts as an on-chain ledger: every proposal,
///         approval and execution is recorded as an event, letting
///         off-chain monitoring (Cloudflare worker, dashboard) pick up
///         the data, generate pre-distribution reports and flag anomalies
///         before signers commit.
///
/// @dev    Trust assumptions:
///         - {token} is the canonical $BLOKC ERC20Votes token.
///         - {factory} is a genuine {BLOKCContributorFactory} whose
///           {predictContributorAccount} returns valid deterministic
///           addresses.
///         - The proposer (AI wallet) is trusted to submit fair scores,
///           but is gated by unanimous signer approval so no single
///           key can move tokens.
///         - The owner is a DAO multisig that manages signers and can
///           recover tokens.
///
///         Tokens are sent to predicted addresses (not deployed clones)
///         — the same pre-fund pattern documented in the factory.
contract BLOKCDistributor {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The canonical $BLOKC ERC20Votes token.
    address public immutable token;

    /// @notice The factory used to predict contributor account addresses.
    BLOKCContributorFactory public immutable factory;

    /// @notice The AI wallet authorized to propose distributions.
    address public proposer;

    /// @notice The admin address that manages signers and the proposer.
    address public owner;

    /// @notice The list of authorized signers. All signers must approve
    ///         before a distribution can be executed. The minimum number
    ///         of signers is 2, enforced at construction and on removal.
    address[] public signers;

    /// @notice Quick lookup: is this address an authorized signer?
    mapping(address => bool) public isSigner;

    /// @notice Per-epoch distribution data.
    mapping(uint256 => Distribution) public distributions;

    /// @notice Per-epoch, per-signer approval tracking.
    mapping(uint256 => mapping(address => bool)) public approvals;

    /*//////////////////////////////////////////////////////////////
                             DISTRIBUTION STRUCT
    //////////////////////////////////////////////////////////////*/

    /// @notice A proposed distribution for one epoch.
    /// @dev    Stored in storage; contributors and amounts arrays are
    ///         persisted so signers and executors can read them.
    struct Distribution {
        address[] contributors;
        uint256[] amounts;
        uint256 approvalCount;
        uint256 requiredApprovals;
        bool executed;
        uint256 proposedAt;
        address[] signerSnapshot; // signer identities AT proposal time (not just count)
    }

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the AI proposer submits a new distribution.
    /// @param epochId      The epoch identifier.
    /// @param totalAmount  Sum of all amounts in this distribution (indexed
    ///                     for gas-efficient off-chain filtering).
    /// @param contributors The contributor addresses in this distribution.
    /// @param amounts      The reward amount for each contributor (in wei).
    event DistributionProposed(
        uint256 indexed epochId, uint256 indexed totalAmount, address[] contributors, uint256[] amounts
    );

    /// @notice Emitted when a signer approves a proposed distribution.
    /// @param epochId       The epoch being approved.
    /// @param signer        The signer who approved.
    /// @param approvalCount Current approval count (including this one).
    event DistributionApproved(uint256 indexed epochId, address indexed signer, uint256 approvalCount);

    /// @notice Emitted when a distribution has been executed.
    /// @param epochId          The epoch that was executed.
    /// @param totalAmount      Total $BLOKC transferred out.
    /// @param contributorCount Number of contributors in this distribution.
    event DistributionExecuted(uint256 indexed epochId, uint256 totalAmount, uint256 contributorCount);

    /// @notice Emitted when the proposer cancels an unexecuted distribution.
    /// @param epochId The epoch that was cancelled.
    event DistributionCancelled(uint256 indexed epochId);

    /// @notice Emitted when a signer is added.
    /// @param signer The new signer address.
    event SignerAdded(address indexed signer);

    /// @notice Emitted when a signer is removed.
    /// @param signer The removed signer address.
    event SignerRemoved(address indexed signer);

    /// @notice Emitted when the proposer address is updated.
    /// @param oldProposer The previous proposer.
    /// @param newProposer The new proposer.
    event ProposerUpdated(address indexed oldProposer, address indexed newProposer);

    /// @notice Emitted when the owner address is updated.
    /// @param oldOwner The previous owner.
    /// @param newOwner The new owner.
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when the owner recovers tokens from this contract.
    /// @param recoveredToken The ERC20 token that was recovered.
    /// @param to             The recipient address.
    /// @param amount         The amount transferred.
    event TokensRecovered(address indexed recoveredToken, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotProposer();
    error NotSigner();
    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroLength();
    error LengthMismatch();
    error InvalidEpochId();
    error AlreadyProposed();
    error DistributionNotFound();
    error AlreadyExecuted();
    error AlreadyApproved();
    error DuplicateSigner();
    error DuplicateContributor(); // same contributor appears twice in a proposal
    error InsufficientSigners(); // fewer than 2 signers
    error InsufficientApprovals(); // not all signers have approved
    error InsufficientBalance();
    error SameAddress();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProposer() {
        if (msg.sender != proposer) revert NotProposer();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Binds the distributor to the $BLOKC token, factory, AI proposer,
    ///         owner and initial signers. All signers must approve every
    ///         distribution. Minimum 2 signers enforced at deployment.
    /// @param _token    The canonical $BLOKC token. Must be non-zero.
    /// @param _factory  The contributor account factory. Must be non-zero.
    /// @param _proposer The AI wallet authorized to propose distributions. Must be non-zero.
    /// @param _owner    The admin address. Must be non-zero.
    /// @param _signers  The initial set of authorized signers. Must contain at
    ///                  least 2 addresses, each non-zero and unique.
    constructor(
        address _token,
        BLOKCContributorFactory _factory,
        address _proposer,
        address _owner,
        address[] memory _signers
    ) {
        if (_token == address(0)) revert ZeroAddress();
        if (address(_factory) == address(0)) revert ZeroAddress();
        if (_proposer == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        token = _token;
        factory = _factory;
        proposer = _proposer;
        owner = _owner;

        for (uint256 i = 0; i < _signers.length; ++i) {
            address signer = _signers[i];
            if (signer == address(0)) revert ZeroAddress();
            if (isSigner[signer]) revert DuplicateSigner();
            isSigner[signer] = true;
            signers.push(signer);
            emit SignerAdded(signer);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           PROPOSE (AI ONLY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Proposes a new reward distribution for an epoch.
    /// @dev    CEI: stores the distribution BEFORE emitting the event so
    ///         off-chain listeners see consistent state. Each epoch can
    ///         only be proposed once. The proposer may cancel and
    ///         re-propose if corrections are needed before any approvals.
    /// @param epochId      The epoch identifier. Must be non-zero and not
    ///                     already proposed.
    /// @param contributors Array of contributor addresses. Must be non-empty,
    ///                     match `amounts` in length, and contain no zero
    ///                     addresses.
    /// @param amounts      Array of reward amounts (in wei). Must be non-empty,
    ///                     match `contributors` in length, and contain no zero
    ///                     amounts.
    function proposeDistribution(uint256 epochId, address[] calldata contributors, uint256[] calldata amounts)
        external
        onlyProposer
    {
        if (epochId == 0) revert InvalidEpochId();
        uint256 length = contributors.length;
        if (length == 0) revert ZeroLength();
        if (amounts.length != length) revert LengthMismatch();

        Distribution storage dist = distributions[epochId];
        if (dist.proposedAt != 0) revert AlreadyProposed();
        if (signers.length < 2) revert InsufficientSigners();

        uint256 totalAmount;
        dist.contributors = contributors;
        dist.amounts = amounts;
        dist.requiredApprovals = signers.length;
        dist.signerSnapshot = signers; // snapshot signer identities at proposal time
        dist.proposedAt = block.timestamp;

        for (uint256 i = 0; i < length; ++i) {
            if (contributors[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert ZeroAmount();
            // Check for duplicate contributors (on-chain defense against double-payment)
            for (uint256 j = 0; j < i; ++j) {
                if (contributors[i] == contributors[j]) revert DuplicateContributor();
            }
            totalAmount += amounts[i];
        }

        emit DistributionProposed(epochId, totalAmount, contributors, amounts);
    }

    /*//////////////////////////////////////////////////////////////
                           APPROVE (SIGNERS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Approves a proposed distribution.
    /// @dev    Each signer may only approve once per epoch. Does NOT
    ///         auto-execute — execution is a separate permissionless call
    ///         so gas costs don't land on the last signer.
    /// @param epochId The epoch to approve.
    function approveDistribution(uint256 epochId) external {
        Distribution storage dist = distributions[epochId];
        if (dist.proposedAt == 0) revert DistributionNotFound();
        if (dist.executed) revert AlreadyExecuted();

        // Verify msg.sender is in the proposal-time signer snapshot (not current signer set)
        bool isProposalSigner;
        uint256 snapshotLen = dist.signerSnapshot.length;
        for (uint256 i = 0; i < snapshotLen; ++i) {
            if (dist.signerSnapshot[i] == msg.sender) {
                isProposalSigner = true;
                break;
            }
        }
        if (!isProposalSigner) revert NotSigner();

        if (approvals[epochId][msg.sender]) revert AlreadyApproved();

        approvals[epochId][msg.sender] = true;
        dist.approvalCount += 1;

        emit DistributionApproved(epochId, msg.sender, dist.approvalCount);
    }

    /*//////////////////////////////////////////////////////////////
                           EXECUTE (PERMISSIONLESS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a distribution once ALL signers have approved.
    /// @dev    CEI: marks executed BEFORE transferring tokens. Sends $BLOKC
    ///         to each contributor's deterministic account address via
    ///         {BLOKCContributorFactory.predictContributorAccount}. The
    ///         account need not be deployed yet — tokens sent to the bare
    ///         address are captured when the factory deploys the clone.
    ///
    ///         Gas: O(n) where n = number of contributors. The dominant
    ///         cost is n × ERC20 transfer (~30k gas each). With dozens of
    ///         contributors this fits well within block limits.
    /// @param epochId The epoch to execute.
    function executeDistribution(uint256 epochId) external {
        Distribution storage dist = distributions[epochId];
        if (dist.proposedAt == 0) revert DistributionNotFound();
        if (dist.executed) revert AlreadyExecuted();
        if (dist.approvalCount < dist.requiredApprovals) revert InsufficientApprovals();

        uint256 length = dist.contributors.length;
        uint256 totalAmount;
        for (uint256 i = 0; i < length; ++i) {
            totalAmount += dist.amounts[i];
        }

        if (IERC20(token).balanceOf(address(this)) < totalAmount) revert InsufficientBalance();

        dist.executed = true;

        for (uint256 i = 0; i < length; ++i) {
            address account = factory.predictContributorAccount(dist.contributors[i]);
            IERC20(token).safeTransfer(account, dist.amounts[i]);
        }

        emit DistributionExecuted(epochId, totalAmount, length);
    }

    /*//////////////////////////////////////////////////////////////
                           CANCEL (PROPOSER ONLY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Cancels an unexecuted distribution so a corrected one can
    ///         be proposed.
    /// @dev    Only callable by the proposer. Once a distribution has been
    ///         executed it cannot be cancelled. Cancellation resets the
    ///         distribution struct and clears all approvals for the epoch
    ///         so signers can re-approve a re-proposed distribution.
    /// @param epochId The epoch to cancel.
    function cancelDistribution(uint256 epochId) external onlyProposer {
        Distribution storage dist = distributions[epochId];
        if (dist.proposedAt == 0) revert DistributionNotFound();
        if (dist.executed) revert AlreadyExecuted();

        // Clear approvals for ALL signers in the proposal-time snapshot (not current signers)
        uint256 len = dist.signerSnapshot.length;
        for (uint256 i = 0; i < len; ++i) {
            delete approvals[epochId][dist.signerSnapshot[i]];
        }

        delete distributions[epochId];

        emit DistributionCancelled(epochId);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN (OWNER ONLY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds a new signer to the authorized set.
    /// @param _signer The address to add. Must be non-zero and not already a signer.
    function addSigner(address _signer) external onlyOwner {
        if (_signer == address(0)) revert ZeroAddress();
        if (isSigner[_signer]) revert AlreadyApproved();

        isSigner[_signer] = true;
        signers.push(_signer);

        emit SignerAdded(_signer);
    }

    /// @notice Removes a signer from the authorized set.
    /// @dev    Reverts if removing this signer would drop the signer count
    ///         below the minimum of 2.
    /// @param _signer The address to remove. Must be a current signer.
    function removeSigner(address _signer) external onlyOwner {
        if (!isSigner[_signer]) revert NotSigner();
        if (signers.length <= 2) revert InsufficientSigners();

        isSigner[_signer] = false;

        uint256 len = signers.length;
        for (uint256 i = 0; i < len; ++i) {
            if (signers[i] == _signer) {
                signers[i] = signers[len - 1];
                signers.pop();
                break;
            }
        }

        emit SignerRemoved(_signer);
    }

    /// @notice Updates the AI proposer address (key rotation, model upgrade).
    /// @param _newProposer The new proposer address. Must be non-zero and
    ///                     different from the current one.
    function updateProposer(address _newProposer) external onlyOwner {
        if (_newProposer == address(0)) revert ZeroAddress();
        if (_newProposer == proposer) revert SameAddress();

        emit ProposerUpdated(proposer, _newProposer);
        proposer = _newProposer;
    }

    /// @notice Transfers ownership to a new address.
    /// @param _newOwner The new owner. Must be non-zero and different from
    ///                  the current owner.
    function updateOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        if (_newOwner == owner) revert SameAddress();

        emit OwnerUpdated(owner, _newOwner);
        owner = _newOwner;
    }

    /// @notice Recovers any ERC20 token held by this contract.
    /// @dev    Used to sweep accumulated dust or mistakenly-sent tokens.
    ///         Unlike {BLOKCContributorAccount.recoverERC20}, this does NOT
    ///         block recovery of $BLOKC itself — the distributor is a
    ///         transient holding contract, not a time-locked vault.
    /// @param _token  The ERC20 token to recover. Must be non-zero.
    /// @param _to     The recipient address. Must be non-zero.
    /// @param _amount The amount to transfer. Must be non-zero and not
    ///                exceed this contract's balance of `_token`.
    function recoverTokens(address _token, address _to, uint256 _amount) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        if (_to == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        if (_amount > IERC20(_token).balanceOf(address(this))) revert InsufficientBalance();

        IERC20(_token).safeTransfer(_to, _amount);
        emit TokensRecovered(_token, _to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the number of authorized signers.
    /// @return The length of the {signers} array.
    function getSignerCount() external view returns (uint256) {
        return signers.length;
    }

    /// @notice Returns whether the given epoch has been proposed.
    /// @param epochId The epoch to check.
    /// @return True if a distribution exists for this epoch (proposed but
    ///         possibly already executed or cancelled).
    function isEpochProposed(uint256 epochId) external view returns (bool) {
        return distributions[epochId].proposedAt != 0;
    }

    /// @notice Returns whether the given epoch has been executed.
    /// @param epochId The epoch to check.
    /// @return True if the distribution for this epoch has been executed.
    function isEpochExecuted(uint256 epochId) external view returns (bool) {
        return distributions[epochId].executed;
    }

    /// @notice Returns the $BLOKC balance held by this distributor.
    /// @return The distributor's current $BLOKC balance.
    function balanceOf() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
