//SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/*###############################################################################

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BLOKCAmbassadorAccount} from "../BLOKCAmbassadorAccount.sol";

/// @title  BLOKCAmbassadorFactory
/// @author BLOK Capital DAO
/// @notice Permissionless factory that deploys {BLOKCAmbassadorAccount}
///         instances as deterministic EIP-1167 minimal-proxy clones, one
///         per ambassador. The CREATE2 salt is the ambassador's wallet
///         address, so each ambassador maps to exactly one knowable
///         account address — letting the team pre-compute and pre-fund
///         an account before that ambassador has ever interacted with
///         the chain.
/// @dev    Implements BIP-002 §11.2–§11.4. Key properties:
///
///         - Permissionless: no owner, no admin, no privileged callers.
///           Anyone may call {createAmbassadorAccount} to deploy their
///           own account, or the address-arg overload to deploy someone
///           else's account on their behalf — the resulting contract is
///           owned by the named ambassador, never by the caller.
///         - Idempotent: a second create call for the same ambassador
///           returns the existing address. The registry never grows
///           past one entry per ambassador.
///         - Single-date lock: {unlockTimestamp} is bound at factory
///           deployment and shared by every account this factory
///           creates. To change the unlock date, deploy a new factory;
///           existing accounts continue to enforce the date they were
///           initialized with.
///
///         Trust assumptions:
///         - {token} is the canonical $BLOKC ERC20Votes token.
///         - {implementation} is a genuine {BLOKCAmbassadorAccount}
///           whose constructor calls `_disableInitializers()`, so the
///           implementation itself can never be initialized directly.
///
///         The contract has no `receive()` or `fallback()`, so native
///         ETH cannot be sent to the factory.
contract BLOKCAmbassadorFactory {
    //this factory is minimal proxy clone factory for BLOKCAmbassadorAccount
    //the only sole purpose of this factory is to deploy simple ambassador accounts
    //using the special proxy to save gas on deployment and nothing more

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The canonical $BLOKC ERC20Votes token address forwarded
    ///         to every account this factory creates.
    /// @dev    Set once at construction; never updatable.
    address public immutable token;

    /// @notice The {BLOKCAmbassadorAccount} implementation that every
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
    ///         equals the number of distinct ambassadors served.
    address[] public accounts;

    /*//////////////////////////////////////////////////////////////
                                MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether the given ambassador already has an account
    ///         deployed by this factory.
    /// @dev    Equivalent to `accountOf[a] != address(0)`; kept as a
    ///         distinct mapping for ergonomic boolean checks.
    mapping(address => bool) public holdsAccount;

    /// @notice The deployed account address for a given ambassador, or
    ///         `address(0)` if no account has been created yet.
    /// @dev    Source of truth for the idempotency short-circuit in
    ///         {_createAmbassadorAccount}.
    mapping(address => address) public accountOf;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted exactly once, when an ambassador's account is
    ///         actually deployed (NOT on idempotent return).
    /// @param ambassador The ambassador the account belongs to.
    /// @param account    The newly deployed account address.
    event AmbassadorAccountCreated(address indexed ambassador, address indexed account);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an address argument is the zero address —
    ///         used by the constructor (token, implementation) and by
    ///         {_createAmbassadorAccount} (ambassador).
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
    ///                         {BLOKCAmbassadorAccount} implementation.
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

    /// @notice Deploys (or returns) the caller's own ambassador account.
    /// @dev    Convenience wrapper around
    ///         {_createAmbassadorAccount}(`msg.sender`). Idempotent — a
    ///         second call from the same address returns the existing
    ///         account address without redeploying or emitting.
    /// @return The caller's deterministic account address.
    function createAmbassadorAccount() external returns (address) {
        return _createAmbassadorAccount(msg.sender);
    }

    /// @notice Deploys (or returns) `ambassador`'s account on their
    ///         behalf.
    /// @dev    Per BIP-002 §11.3 anyone may call this. The resulting
    ///         contract is owned by `ambassador`, NEVER by
    ///         `msg.sender` — the caller simply pays the deploy gas as
    ///         a permissionless courtesy. Idempotent.
    /// @param ambassador The ambassador whose account should be
    ///                   deployed. Must be non-zero.
    /// @return The deterministic account address for `ambassador`.
    function createAmbassadorAccount(address ambassador) external returns (address) {
        return _createAmbassadorAccount(ambassador);
    }

    /*//////////////////////////////////////////////////////////////
                            CREATE — INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Core deploy-or-return routine shared by both create
    ///         entry points.
    /// @dev    On a fresh ambassador:
    ///           1. Clones {implementation} via
    ///              {Clones-cloneDeterministic} with
    ///              `salt = bytes32(uint256(uint160(ambassador)))`.
    ///           2. Records the new account in {accounts},
    ///              {holdsAccount} and {accountOf} BEFORE calling
    ///              `initialize` — so any reentry during the
    ///              `initialize`'s downstream {IVotes-delegate} would
    ///              hit the idempotent short-circuit and short-return.
    ///           3. Calls `initialize(ambassador, token,
    ///              unlockTimestamp)` on the clone, which delegates
    ///              the account's voting power to the ambassador.
    ///           4. Emits {AmbassadorAccountCreated}.
    ///
    ///         On an already-existing ambassador, returns the cached
    ///         account address without redeploying, registering, or
    ///         emitting.
    /// @param ambassador The ambassador for whom to deploy or look up
    ///                   the account. Must be non-zero.
    /// @return The (newly deployed or pre-existing) account address.
    function _createAmbassadorAccount(address ambassador) internal returns (address) {
        if (ambassador == address(0)) revert ZeroAddress();
        address exisiting = accountOf[ambassador];
        if (exisiting != address(0)) {
            return exisiting;
        }

        address ambassadorAccount = Clones.cloneDeterministic(implementation, bytes32(uint256(uint160(ambassador))));
        accounts.push(ambassadorAccount);
        holdsAccount[ambassador] = true;
        accountOf[ambassador] = ambassadorAccount;
        BLOKCAmbassadorAccount(ambassadorAccount).initialize(ambassador, token, unlockTimestamp);
        emit AmbassadorAccountCreated(ambassador, ambassadorAccount);
        return ambassadorAccount;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the deterministic address an ambassador's
    ///         account WILL be — or already IS — deployed at.
    /// @dev    Computed via {Clones-predictDeterministicAddress} using
    ///         the same salt rule as the create path. Useful for
    ///         pre-funding: the team may transfer $BLOKC to the
    ///         predicted address before any deployment occurs; the
    ///         balance is captured by the clone the moment
    ///         {_createAmbassadorAccount} runs.
    /// @param ambassador The ambassador whose account address to
    ///                   predict.
    /// @return The CREATE2 address derived from
    ///         (`implementation`, salt, `address(this)`).
    function predictAmbassadorAccount(address ambassador) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, bytes32(uint256(uint160(ambassador))), address(this));
    }

    /// @notice Returns the full list of ambassador account addresses
    ///         deployed by this factory.
    /// @dev    Length equals the number of distinct ambassadors
    ///         served. Idempotent re-creates do not increase length.
    /// @return Snapshot of the {accounts} array.
    function getAllAccounts() external view returns (address[] memory) {
        return accounts;
    }

    /// @notice Returns the account address for `ambassador`, or
    ///         `address(0)` if none has been created yet.
    /// @dev    Verb-named alias for the auto-getter on {accountOf}.
    /// @param ambassador The ambassador to look up.
    /// @return The account address, or zero if no account exists.
    function getAccountOf(address ambassador) external view returns (address) {
        return accountOf[ambassador];
    }

    /// @notice Reports whether `ambassador` already has a deployed
    ///         account.
    /// @dev    Verb-named alias for the auto-getter on {holdsAccount}.
    /// @param ambassador The ambassador to check.
    /// @return True if an account exists, false otherwise.
    function hasAccount(address ambassador) external view returns (bool) {
        return holdsAccount[ambassador];
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
