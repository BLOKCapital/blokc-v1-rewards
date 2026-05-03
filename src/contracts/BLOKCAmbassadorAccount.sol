//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*###############################################################################

/// @title  BLOKCAmbassadorAccount
/// @author BLOK Capital DAO
/// @notice Per-ambassador time-locked rewards account. Holds $BLOKC accrued
///         by an ambassador over time and releases the full balance after a
///         single unlock timestamp (1 May 2027 00:00 UTC for the production
///         deploy). Before unlock the balance is locked at the bytecode
///         level; after unlock the ambassador may withdraw any amount, to
///         any address, at any time.
///
///         Throughout the lock period, voting power on the held $BLOKC is
///         delegated to the ambassador, so locked tokens still count toward
///         governance weight. This implements the "locked $BLOKC retains
///         governance rights" principle from BIP-001 / BIP-002.
///
/// @dev    Deployed as an EIP-1167 minimal-proxy clone by the
///         {BLOKCAmbassadorFactory}, which uses CREATE2 with the
///         ambassador's address as the salt:
///
///             salt = bytes32(uint256(uint160(ambassador)))
///
///         Every ambassador therefore maps to exactly one deterministic
///         account address that can be pre-computed and pre-funded before
///         this contract has been deployed.
///
///         Trust assumptions and invariants:
///         - {token} is the canonical $BLOKC ERC20Votes token. It is set
///           once in {initialize} and never updated.
///         - {unlockTimestamp} is set once in {initialize} and never
///           updated; there is no setter, no admin override, no pause and
///           no DAO escape hatch. To change the unlock date, deploy a new
///           factory + implementation and migrate forward.
///         - The implementation contract itself cannot be initialized;
///           only EIP-1167 clones can ({Initializable}).
///         - The contract has no `receive()` or `fallback()`, so native
///           ETH cannot be sent in.
///
///         See BIP-002 for the governance rationale and
///         BLOKC-Vesting-Tech-Spec.md for architectural decisions.

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract BLOKCAmbassadorAccount is Initializable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The $BLOKC ERC20Votes token bound to this account.
    /// @dev    Set once in {initialize} and never updated. {recoverERC20}
    ///         reverts if invoked with this address — $BLOKC is the only
    ///         asset subject to the lock and is never recoverable through
    ///         that path.
    address public token;

    /// @notice The ambassador (beneficiary / owner) of this account.
    /// @dev    Set once in {initialize} and never updated. The CREATE2
    ///         salt used by the factory is the ambassador's address, so
    ///         this value uniquely identifies the account on-chain.
    address public ambassador;

    /// @notice Unix timestamp (seconds) at which the locked $BLOKC
    ///         becomes withdrawable.
    /// @dev    The unlock predicate is `block.timestamp >= unlockTimestamp`,
    ///         so withdrawals succeed at exactly the unlock second. Set
    ///         once in {initialize} and never updated.
    uint64 public unlockTimestamp;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the ambassador redirects the account's voting
    ///         power to a new delegatee via {reDelegate}.
    /// @param to The new delegatee chosen by the ambassador.
    event Redelegated(address indexed to);

    /// @notice Emitted when the ambassador sweeps the account's full
    ///         $BLOKC balance to themselves via {withdrawTokensAll}.
    /// @param ambassador The recipient — always the account's ambassador.
    /// @param balance    The full $BLOKC balance that was transferred out.
    event AllTokensWithdrawn(address indexed ambassador, uint256 balance);

    /// @notice Emitted on a partial post-unlock withdrawal via {withdraw}.
    /// @param to     The recipient chosen by the ambassador.
    /// @param amount The amount of $BLOKC transferred.
    event Withdrawn(address indexed to, uint256 amount);

    /// @notice Emitted exactly once when this clone is initialized by
    ///         {BLOKCAmbassadorFactory}.
    /// @param ambassador      The ambassador bound to this account.
    /// @param token           The $BLOKC token address bound to this account.
    /// @param unlockTimestamp The unlock timestamp baked into this account.
    event Initialized(address indexed ambassador, address indexed token, uint64 unlockTimestamp);

    /// @notice Emitted when a non-$BLOKC ERC20 token mistakenly sent to
    ///         this account is recovered via {recoverERC20}.
    /// @param token  The recovered ERC20 (always != $BLOKC).
    /// @param to     The recipient chosen by the ambassador.
    /// @param amount The amount of `token` transferred out.
    event NonBLOKCTokensRecovered(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function gated by {onlyAmbassador} is called
    ///         by anyone other than the bound ambassador.
    error NotAnAmbassador();

    /// @notice Thrown when a withdrawal is attempted before
    ///         `block.timestamp >= unlockTimestamp`.
    error NoTimelineUnlockedYet();

    /// @notice Thrown when {initialize} is given an unlock timestamp of
    ///         zero, which would imply an immediately-unlocked account.
    error ZeroTimestamp();

    /// @notice Thrown when an address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a token-amount argument is zero.
    error ZeroAmount();

    /// @notice Thrown when this account holds less of the relevant token
    ///         than the requested operation requires.
    error InsufficientBalance();

    /// @notice Thrown when {recoverERC20} is called with the $BLOKC token
    ///         address — $BLOKC is never recoverable through that path.
    error InvalidERC20Token();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Locks the implementation contract so it can never be
    ///         initialized directly.
    /// @dev    All real ambassador accounts are EIP-1167 clones of this
    ///         implementation; only those clones go through {initialize}.
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice One-shot initializer called by {BLOKCAmbassadorFactory}
    ///         immediately after the clone is deployed. Binds the
    ///         ambassador, the $BLOKC token and the unlock timestamp,
    ///         and delegates the account's voting power to the
    ///         ambassador.
    /// @dev    All storage is written before the external
    ///         {IVotes-delegate} call (CEI), so even a malicious token
    ///         supplied here cannot observe inconsistent state via
    ///         re-entry. Subsequent calls revert via the `initializer`
    ///         modifier from {Initializable}.
    /// @param _ambassador      The ambassador that will own this account.
    ///                         Must be non-zero.
    /// @param _token           The $BLOKC ERC20Votes token address.
    ///                         Must be non-zero.
    /// @param _unlockTimestamp Unix timestamp at which $BLOKC becomes
    ///                         withdrawable. Must be non-zero.
    function initialize(address _ambassador, address _token, uint64 _unlockTimestamp) external initializer {
        //some basic sanity checks

        if (_ambassador == address(0)) {
            revert ZeroAddress();
        }

        if (_token == address(0)) {
            revert ZeroAddress();
        }
        if (_unlockTimestamp == 0) {
            revert ZeroTimestamp();
        }

        ambassador = _ambassador;
        token = _token;
        unlockTimestamp = _unlockTimestamp;

        emit Initialized(ambassador, token, unlockTimestamp);

        IVotes(token).delegate(ambassador);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts a function to the bound ambassador.
    /// @dev    Reverts with {NotAnAmbassador} if `msg.sender` is not the
    ///         ambassador set in {initialize}. Note that the account can
    ///         still be funded by anyone via plain ERC20 transfers — only
    ///         state-mutating operations on the account itself are gated.
    ///         {onlyAmbassador} is used in place of an `onlyDAO` pattern
    ///         intentionally: ambassador accounts require no DAO interaction.
    modifier onlyAmbassador() {
        if (msg.sender != ambassador) {
            revert NotAnAmbassador();
        }
        _;
    }

    /// @notice Restricts a function to executions at or after the unlock
    ///         timestamp.
    /// @dev    Reverts with {NoTimelineUnlockedYet} when
    ///         `block.timestamp < unlockTimestamp`. Succeeds at exactly
    ///         `block.timestamp == unlockTimestamp`.
    modifier onlyAfterUnlockTimestamp() {
        if (unlockTimestamp > block.timestamp) {
            revert NoTimelineUnlockedYet();
        }

        _;
    }

    /*//////////////////////////////////////////////////////////////
                          DELEGATION INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal helper that delegates the account's voting power
    ///         to `_to`, with a zero-address guard.
    /// @dev    Used by {reDelegate}. Reverts with {ZeroAddress} on a zero
    ///         delegatee.
    /// @param _to The new delegatee for the account's $BLOKC votes.
    function _delegate(address _to) internal {
        if (_to == address(0)) {
            revert ZeroAddress();
        }

        IVotes(token).delegate(_to);
    }

    /*//////////////////////////////////////////////////////////////
                          AMBASSADOR ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Redirects the account's voting power to a new delegatee.
    /// @dev    Callable at any time, before or after unlock — the lock
    ///         applies to fund movement, not to governance routing.
    ///         Restricted to the ambassador via {onlyAmbassador}. Emits
    ///         {Redelegated} on success.
    /// @param _to The new delegatee. Must be non-zero (enforced by
    ///            {_delegate}).
    function reDelegate(address _to) external onlyAmbassador {
        _delegate(_to);

        emit Redelegated(_to);
    }

    /// @notice Recovers a non-$BLOKC ERC20 token mistakenly sent to this
    ///         account.
    /// @dev    Available at any time, including before unlock — the lock
    ///         only protects $BLOKC. Reverts unconditionally with
    ///         {InvalidERC20Token} when called with the bound {token}
    ///         address. Restricted to the ambassador via {onlyAmbassador}.
    ///         Emits {NonBLOKCTokensRecovered}.
    /// @param ERC20token The foreign ERC20 to recover. Must be non-zero
    ///                   and must NOT equal {token}.
    /// @param to         The recipient chosen by the ambassador. Must be
    ///                   non-zero.
    /// @param amount     Amount to transfer. Must be non-zero and not
    ///                   exceed this account's balance of `ERC20token`.
    function recoverERC20(address ERC20token, address to, uint256 amount) external onlyAmbassador {
        if (ERC20token == address(0)) {
            revert ZeroAddress();
        }
        if (ERC20token == token) {
            revert InvalidERC20Token();
        }

        if (to == address(0)) {
            revert ZeroAddress();
        }

        if (amount == 0) {
            revert ZeroAmount();
        }

        if (amount > IERC20(ERC20token).balanceOf(address(this))) {
            revert InsufficientBalance();
        }

        IERC20(ERC20token).safeTransfer(to, amount);

        emit NonBLOKCTokensRecovered(ERC20token, to, amount);
    }

    /// @notice Withdraws a partial amount of $BLOKC after unlock.
    /// @dev    Reverts with {NoTimelineUnlockedYet} before unlock and
    ///         with {InsufficientBalance} if the account lacks the
    ///         requested amount. Restricted to the ambassador via
    ///         {onlyAmbassador}. The recipient may be any non-zero
    ///         address — not only the ambassador. Emits {Withdrawn}.
    /// @param to     Recipient address. Must be non-zero.
    /// @param amount Amount of $BLOKC to transfer. Must be non-zero and
    ///               not exceed this account's $BLOKC balance.
    function withdraw(address to, uint256 amount) external onlyAmbassador onlyAfterUnlockTimestamp {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (IERC20(token).balanceOf(address(this)) == 0) {
            revert InsufficientBalance();
        }
        if (amount > IERC20(token).balanceOf(address(this))) {
            revert InsufficientBalance();
        }

        IERC20(token).safeTransfer(to, amount);

        emit Withdrawn(to, amount);
    }

    /// @notice Sweeps the entire $BLOKC balance of this account to the
    ///         ambassador.
    /// @dev    Reverts with {NoTimelineUnlockedYet} before unlock and
    ///         {InsufficientBalance} if the account is empty. Restricted
    ///         to the ambassador via {onlyAmbassador}. The destination is
    ///         always the ambassador by design — for arbitrary recipients
    ///         use {withdraw}. Emits {AllTokensWithdrawn}.
    function withdrawTokensAll() external onlyAmbassador onlyAfterUnlockTimestamp {
        if (IERC20(token).balanceOf(address(this)) == 0) {
            revert InsufficientBalance();
        }

        uint256 Currentbalance = IERC20(token).balanceOf(address(this));
        if (Currentbalance == 0) {
            revert InsufficientBalance();
        }

        IERC20(token).safeTransfer(ambassador, Currentbalance);

        emit AllTokensWithdrawn(ambassador, Currentbalance);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the $BLOKC balance currently held by this account.
    /// @dev    Convenience wrapper around
    ///         `IERC20(token).balanceOf(address(this))`.
    /// @return The account's current $BLOKC balance.
    function balanceOf() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Returns the unlock timestamp set at initialization.
    /// @dev    Verb-named alternative to the auto-generated public getter
    ///         for {unlockTimestamp}.
    /// @return The unlock timestamp (Unix seconds, uint64).
    function getUnlockTimestamp() external view returns (uint64) {
        return unlockTimestamp;
    }

    /// @notice Reports whether the account is currently unlocked.
    /// @dev    Returns `true` from the unlock second onward.
    /// @return True if `block.timestamp >= unlockTimestamp`, else false.
    function isUnlocked() external view returns (bool) {
        return block.timestamp >= unlockTimestamp;
    }

    /// @notice Returns the number of seconds remaining until unlock.
    /// @dev    Returns 0 once the unlock has occurred.
    /// @return Seconds until unlock, or 0 if already unlocked.
    function timeUntilUnlock() external view returns (uint256) {
        return block.timestamp >= unlockTimestamp ? 0 : unlockTimestamp - block.timestamp;
    }
}

