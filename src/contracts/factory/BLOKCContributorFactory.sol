//SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/*###############################################################################

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BLOKCContributorAccount} from "../BLOKCContributorAccount.sol";

/// @title  BLOKCContributorFactory
/// @author BLOK Capital DAO
/// @notice Permissionless factory that deploys {BLOKCContributorAccount}
///         instances as deterministic EIP-1167 minimal-proxy clones, one
///         per contributor. The CREATE2 salt is the contributor's wallet
///         address, so each contributor maps to exactly one knowable
///         account address — letting the team pre-compute and pre-fund
///         an account before that contributor has ever interacted with
///         the chain.
/// @dev    Implements BIP-002 §11.2–§11.4. Key properties:
///
///         - Self-deploy only: no owner, no admin, no privileged callers.
///           A contributor may only call {createContributorAccount} to
///           deploy their own account — no one can deploy on someone
///           else's behalf.
///         - Idempotent: a second create call for the same contributor
///           returns the existing address. The registry never grows
///           past one entry per contributor.
///         - Single-date lock: {unlockTimestamp} is bound at factory
///           deployment and shared by every account this factory
///           creates. To change the unlock date, deploy a new factory;
///           existing accounts continue to enforce the date they were
///           initialized with.
///
///         Trust assumptions:
///         - {token} is the canonical $BLOKC ERC20Votes token.
///         - {implementation} is a genuine {BLOKCContributorAccount}
///           whose constructor calls `_disableInitializers()`, so the
///           implementation itself can never be initialized directly.
///
///         The contract has no `receive()` or `fallback()`, so native
///         ETH cannot be sent to the factory.
contract BLOKCContributorFactory {
    //this factory is minimal proxy clone factory for BLOKCContributorAccount
    //the only sole purpose of this factory is to deploy simple contributor accounts
    //using the special proxy to save gas on deployment and nothing more

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The canonical $BLOKC ERC20Votes token address forwarded
    ///         to every account this factory creates.
    /// @dev    Set once at construction; never updatable.
    address public immutable token;

    /// @notice The {BLOKCContributorAccount} implementation that every
    ///         deployed clone delegates execution to.
    /// @dev    Set once at construction. Pinning the implementation
    ///         here means the clone bytecode at any predicted address
    ///         is knowable in advance.
    address public immutable implementation;

    /// @notice Unix timestamp (seconds) at which every account this
    ///         factory creates becomes withdrawable.
    /// @dev    Shared by all clones from this factory. Per BIP-002
    ///         §11.4, this is bytecode-level immutable per account; the
    ///         only way to change the unlock date is to deploy a new
    ///         factory.
    uint64 public immutable unlockTimestamp;

    /*//////////////////////////////////////////////////////////////
                                REGISTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice Append-only list of every account address deployed by
    ///         this factory.
    /// @dev    Idempotent re-creates do NOT push; the array length
    ///         equals the number of distinct contributors served.
    address[] public accounts;

    /*//////////////////////////////////////////////////////////////
                                MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether the given contributor already has an account
    ///         deployed by this factory.
    /// @dev    Equivalent to `accountOf[a] != address(0)`; kept as a
    ///         distinct mapping for ergonomic boolean checks.
    mapping(address => bool) public holdsAccount;

    /// @notice The deployed account address for a given contributor, or
    ///         `address(0)` if no account has been created yet.
    /// @dev    Source of truth for the idempotency short-circuit in
    ///         {_createContributorAccount}.
    mapping(address => address) public accountOf;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted exactly once, when a contributor's account is
    ///         actually deployed (NOT on idempotent return).
    /// @param contributor The contributor the account belongs to.
    /// @param account    The newly deployed account address.
    event ContributorAccountCreated(address indexed contributor, address indexed account);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an address argument is the zero address —
    ///         used by the constructor (token, implementation) and by
    ///         {_createContributorAccount} (contributor).
    error ZeroAddress();

    /// @notice Thrown when the constructor is given an unlock timestamp of
    ///         zero, which would make every clone's {initialize} revert and
    ///         permanently brick the factory.
    error ZeroTimestamp();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Binds the factory to a $BLOKC token, an account
    ///         implementation, and a single uniform unlock timestamp.
    /// @dev    All three values are stored as `immutable`. There is no
    ///         setter for any of them — to change them, deploy a new
    ///         factory.
    /// @param _token           Canonical $BLOKC ERC20Votes token.
    ///                         Must be non-zero.
    /// @param _implementation  Address of the deployed
    ///                         {BLOKCContributorAccount} implementation.
    ///                         Must be non-zero.
    /// @param _unlockTimestamp Unix timestamp (seconds) at which all
    ///                         clones from this factory unlock. Must be
    ///                         non-zero.
    constructor(address _token, address _implementation, uint64 _unlockTimestamp) {
        if (_implementation == address(0)) {
            revert ZeroAddress();
        }
        if (_token == address(0)) {
            revert ZeroAddress();
        }
        if (_unlockTimestamp == 0) {
            revert ZeroTimestamp();
        }

        token = _token;
        implementation = _implementation;
        unlockTimestamp = _unlockTimestamp;
    }

    /*//////////////////////////////////////////////////////////////
                            CREATE — EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys (or returns) the caller's own contributor account.
    /// @dev    Calls {_createContributorAccount}(`msg.sender`). A
    ///         contributor can only create an account for themselves — no
    ///         third party can deploy on someone else's behalf. Idempotent:
    ///         a second call returns the existing address without
    ///         redeploying or emitting.
    /// @return The caller's deterministic account address.
    function createContributorAccount() external returns (address) {
        return _createContributorAccount(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            CREATE — INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Core deploy-or-return routine.
    /// @dev    On a fresh contributor:
    ///           1. Clones {implementation} via
    ///              {Clones-cloneDeterministic} with
    ///              `salt = bytes32(uint256(uint160(contributor)))`.
    ///           2. Records the new account in {accounts},
    ///              {holdsAccount} and {accountOf} BEFORE calling
    ///              `initialize` — so any reentry during the
    ///              `initialize`'s downstream {IVotes-delegate} would
    ///              hit the idempotent short-circuit and short-return.
    ///           3. Calls `initialize(contributor, token,
    ///              unlockTimestamp)` on the clone, which delegates
    ///              the account's voting power to the contributor.
    ///           4. Emits {ContributorAccountCreated}.
    ///
    ///         On an already-existing contributor, returns the cached
    ///         account address without redeploying, registering, or
    ///         emitting.
    /// @param contributor The contributor for whom to deploy or look up
    ///                   the account. Must be non-zero.
    /// @return The (newly deployed or pre-existing) account address.
    function _createContributorAccount(address contributor) internal returns (address) {
        if (contributor == address(0)) revert ZeroAddress();
        address exisiting = accountOf[contributor];
        if (exisiting != address(0)) {
            return exisiting;
        }

        address contributorAccount = Clones.cloneDeterministic(implementation, bytes32(uint256(uint160(contributor))));
        accounts.push(contributorAccount);
        holdsAccount[contributor] = true;
        accountOf[contributor] = contributorAccount;
        BLOKCContributorAccount(contributorAccount).initialize(contributor, token, unlockTimestamp);
        emit ContributorAccountCreated(contributor, contributorAccount);
        return contributorAccount;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the deterministic address a contributor's
    ///         account WILL be — or already IS — deployed at.
    /// @dev    Computed via {Clones-predictDeterministicAddress} using
    ///         the same salt rule as the create path. Useful for
    ///         pre-funding: the team may transfer $BLOKC to the
    ///         predicted address before any deployment occurs; the
    ///         balance is captured by the clone the moment
    ///         {_createContributorAccount} runs.
    /// @param contributor The contributor whose account address to
    ///                   predict.
    /// @return The CREATE2 address derived from
    ///         (`implementation`, salt, `address(this)`).
    function predictContributorAccount(address contributor) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, bytes32(uint256(uint160(contributor))), address(this));
    }

    /// @notice Number of contributor accounts deployed by this factory.
    /// @dev    Equals the number of distinct contributors served;
    ///         idempotent re-creates do not increase it. Pair with
    ///         {getAccounts} to page through the registry without ever
    ///         loading the whole array in a single call.
    /// @return The length of the {accounts} array.
    function getAccountsLength() external view returns (uint256) {
        return accounts.length;
    }

    /// @notice Returns a bounded slice ("page") of the {accounts} array.
    /// @dev    Deliberately replaces an unbounded "return the whole array"
    ///         getter. That pattern's gas and return size grow with the
    ///         registry and eventually make the call exceed node gas /
    ///         response limits off-chain (and block-gas limits on-chain) —
    ///         a denial-of-service as the registry scales, with no knob for
    ///         the reader. Here the caller chooses the page size, so each
    ///         call costs O(limit) regardless of how large the registry
    ///         grows. An `offset` at or past the end yields an empty page,
    ///         and the window is clamped to the array length, so any
    ///         `limit` (including `type(uint256).max`) is safe and never
    ///         reverts.
    /// @param offset Index of the first account to return.
    /// @param limit  Maximum number of accounts to return.
    /// @return page  The accounts in `[offset, min(offset + limit, length))`.
    function getAccounts(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 len = accounts.length;
        if (offset >= len) {
            return new address[](0);
        }

        // `offset < len` here, so `len - offset` cannot underflow and
        // `offset + i` below cannot overflow — no need to add `limit` to
        // `offset` (which could overflow for a huge `limit`).
        uint256 remaining = len - offset;
        uint256 count = limit < remaining ? limit : remaining;

        page = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            page[i] = accounts[offset + i];
        }
    }

    /// @notice Returns the account address for `contributor`, or
    ///         `address(0)` if none has been created yet.
    /// @dev    Verb-named alias for the auto-getter on {accountOf}.
    /// @param contributor The contributor to look up.
    /// @return The account address, or zero if no account exists.
    function getAccountOf(address contributor) external view returns (address) {
        return accountOf[contributor];
    }

    /// @notice Reports whether `contributor` already has a deployed
    ///         account.
    /// @dev    Verb-named alias for the auto-getter on {holdsAccount}.
    /// @param contributor The contributor to check.
    /// @return True if an account exists, false otherwise.
    function hasAccount(address contributor) external view returns (bool) {
        return holdsAccount[contributor];
    }

    /// @notice Returns the uniform unlock timestamp shared by every
    ///         account this factory creates.
    /// @dev    Verb-named alias for the auto-getter on
    ///         {unlockTimestamp}.
    /// @return The unlock timestamp (Unix seconds, uint64).
    function getUnlockTimestamp() external view returns (uint64) {
        return unlockTimestamp;
    }

    /// @notice Returns the $BLOKC token address forwarded to every
    ///         account this factory creates.
    /// @dev    Verb-named alias for the auto-getter on {token}.
    /// @return The bound $BLOKC token address.
    function getToken() external view returns (address) {
        return token;
    }
}
