// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "test/utils/BaseTest.sol";
import {BLOKCAmbassadorAccount} from "src/contracts/BLOKCAmbassadorAccount.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Constants} from "test/utils/Constants.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title  BLOKCAmbassadorAccountTest
/// @notice Unit tests for {BLOKCAmbassadorAccount}.
/// @dev    Inherits the shared harness in {BaseTest}, which deploys the
///         mock $BLOKC token, the account implementation and the factory,
///         materialises the named user set, and pins `block.timestamp`
///         to `Constants.START_TIMESTAMP` (one year before unlock).
///
///         Tests exercise the contract's external surface:
///           - {initialize}            : argument validation, double-init guard, impl-init guard.
///           - {reDelegate}            : auth gate, zero-delegatee guard, vote-power movement, pre/post unlock.
///           - {recoverERC20}          : auth gate, $BLOKC blocklist, arg validation, insufficient balance.
///           - {withdraw}              : auth gate, time gate (with boundary), arg validation, balance checks.
///           - {withdrawTokensAll}     : auth gate, time gate (with boundary), empty-balance revert, full sweep.
///
///         Two local helpers ({_clone}, {_initializedClone}) sit alongside
///         the BaseTest helpers ({_createAccount}, {_fundAccount},
///         {_fundedAccount}, {_warpToUnlock} family) used throughout.
contract BLOKCAmbassadorAccountTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys a fresh EIP-1167 minimal-proxy clone of the
    ///         account implementation **without initializing it**.
    /// @dev    Used by {initialize} tests that need a raw, uninitialized
    ///         clone so they can call `initialize` with bad arguments
    ///         and observe the relevant revert. The implementation
    ///         itself is locked (`_disableInitializers()` in the
    ///         constructor), so direct-init tests use the inherited
    ///         {implementation} instead of this helper.
    /// @return clone A labelled, uninitialized clone of {implementation}.
    function _clone() internal returns (BLOKCAmbassadorAccount clone) {
        clone = BLOKCAmbassadorAccount(Clones.clone(address(implementation)));
        vm.label(address(clone), "Clone");
        return clone;
    }

    /// @notice Deploys a clone via {_clone} and initializes it with the
    ///         canonical (`users.ambassador`, `blokc`, `UNLOCK_TIMESTAMP`)
    ///         triple.
    /// @dev    Convenience wrapper for tests that need an already-init'd
    ///         clone (e.g. the double-initialize check). Does NOT mint
    ///         any $BLOKC into the clone — use {_fundedAccount} from
    ///         {BaseTest} for that.
    /// @return clone An initialized clone bound to `users.ambassador`.
    function _initializedClone() internal returns (BLOKCAmbassadorAccount clone) {
        clone = _clone();
        clone.initialize(users.ambassador, address(blokc), Constants.UNLOCK_TIMESTAMP);
        return clone;
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    //test the initialize function
    /// @notice Asserts the three zero-argument guards in {initialize}:
    ///         zero ambassador → {ZeroAddress}, zero token → {ZeroAddress},
    ///         zero unlock timestamp → {ZeroTimestamp}.
    /// @dev    All three sub-cases run against the same uninitialized
    ///         clone — since each `initialize` call reverts, the clone
    ///         stays uninitialized and can be reused for the next case.
    function test_initialize_zeroAddress() public {
        //simple zero address overall initialize tests
        BLOKCAmbassadorAccount clone = _clone();
        vm.expectRevert(BLOKCAmbassadorAccount.ZeroAddress.selector);
        clone.initialize(address(0), address(blokc), Constants.UNLOCK_TIMESTAMP);

        //revert if the token is the zero address
        vm.expectRevert(BLOKCAmbassadorAccount.ZeroAddress.selector);
        clone.initialize(users.ambassador, address(0), Constants.UNLOCK_TIMESTAMP);

        //revert if the unlock timestamp is zero
        vm.expectRevert(BLOKCAmbassadorAccount.ZeroTimestamp.selector);
        clone.initialize(users.ambassador, address(blokc), 0);
    }

    /// @notice Asserts that a second {initialize} call on an already
    ///         initialized clone reverts with OZ's
    ///         {Initializable.InvalidInitialization}.
    /// @dev    The error lives on OpenZeppelin's {Initializable}, not on
    ///         {BLOKCAmbassadorAccount} itself — that's why the selector
    ///         is namespaced to `Initializable`.
    function test_initialze_twiceInitializeCheck() public {
        BLOKCAmbassadorAccount clone = _initializedClone();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(users.ambassador, address(blokc), Constants.UNLOCK_TIMESTAMP);
    }

    /// @notice Asserts that the **implementation** itself can never be
    ///         initialized directly — only its clones can.
    /// @dev    The implementation's constructor calls
    ///         `_disableInitializers()`, which marks it as already
    ///         initialized; any direct {initialize} call therefore
    ///         reverts with {Initializable.InvalidInitialization}.
    function test_initialize_revertWhen_InitializedCalledOn_Implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);

        implementation.initialize(users.ambassador, address(blokc), Constants.UNLOCK_TIMESTAMP);
    }

    /// @notice Happy-path: a raw clone initialized directly persists all
    ///         three bound values, emits {Initialized}, and delegates its
    ///         voting power to the ambassador.
    /// @dev    Exercises {initialize} outside the factory so the event and
    ///         the post-state are asserted independently of the create flow.
    ///         The {Initialized} event is emitted before the external
    ///         `delegate` call, so it is checked against the clone address.
    function test_initialize_setsStateAndEmitsAndDelegates() public {
        BLOKCAmbassadorAccount clone = _clone();

        vm.expectEmit(true, true, false, true, address(clone));
        emit Initialized(users.ambassador, address(blokc), Constants.UNLOCK_TIMESTAMP);

        clone.initialize(users.ambassador, address(blokc), Constants.UNLOCK_TIMESTAMP);

        assertEq(clone.ambassador(), users.ambassador, "ambassador stored");
        assertEq(clone.token(), address(blokc), "token stored");
        assertEq(clone.unlockTimestamp(), Constants.UNLOCK_TIMESTAMP, "unlock stored");
        assertEq(blokc.delegates(address(clone)), users.ambassador, "voting power delegated to ambassador");
    }

    /*//////////////////////////////////////////////////////////////
                              REDELEGATE
    //////////////////////////////////////////////////////////////*/

    //tests on redelegate
    /// @notice Asserts {reDelegate} is gated by `onlyAmbassador`.
    /// @dev    Pranks as `users.attacker` and expects {NotAnAmbassador}.
    function test_redelegate_revertWhen_CalledByNonAmbassador() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCAmbassadorAccount.NotAnAmbassador.selector);
        account.reDelegate(users.delegatee);
    }

    /// @notice Asserts {reDelegate} rejects a zero-address delegatee.
    /// @dev    Pranks as the ambassador so the auth gate passes; the
    ///         internal `_delegate` zero-address guard should then fire
    ///         with {ZeroAddress}.
    function test_redelegate_revertWhen_DelegeteeIsZeroAddress() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.ZeroAddress.selector);
        account.reDelegate(address(0));
    }

    /// @notice Happy-path: re-delegating moves the account's voting
    ///         power from the ambassador to the new delegatee.
    /// @dev    Pre-condition: account is funded, so `getVotes(ambassador)`
    ///         is non-zero on entry. After {reDelegate}:
    ///           - `delegates(account)` points to the new delegatee,
    ///           - ambassador's vote count drops to zero,
    ///           - the delegatee receives the full balance as vote power.
    function test_redelegate_movesVotingPower() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        assertEq(blokc.getVotes(users.ambassador), Constants.DEFAULT_FUND_AMOUNT);

        vm.expectEmit(true, false, false, true, address(account));
        emit Redelegated(users.delegatee);

        vm.prank(users.ambassador);
        account.reDelegate(users.delegatee);

        assertEq(blokc.delegates(address(account)), users.delegatee, "delegate updated");
        assertEq(blokc.getVotes(users.ambassador), 0, "ambassador votes cleared");
        assertEq(blokc.getVotes(users.delegatee), Constants.DEFAULT_FUND_AMOUNT, "delegatee receives votes");
    }

    /// @notice Asserts {reDelegate} keeps working **after** unlock — the
    ///         lock applies to fund movement, not to governance routing.
    /// @dev    Same vote-power assertions as the happy path, but executed
    ///         after `_warpPastUnlock()`. Pins the BIP-002 rule that
    ///         delegation is unrestricted across the entire account lifetime.
    function test_redelegate_worksAfterUnlock() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpPastUnlock();

        vm.prank(users.ambassador);

        account.reDelegate(users.delegatee);

        assertEq(blokc.delegates(address(account)), users.delegatee, "delegate updated");
        assertEq(blokc.getVotes(users.ambassador), 0, "ambassador votes cleared");
        assertEq(blokc.getVotes(users.delegatee), Constants.DEFAULT_FUND_AMOUNT, "delegatee receives votes");
    }

    /*//////////////////////////////////////////////////////////////
                              RECOVER_ERC20
    //////////////////////////////////////////////////////////////*/

    //tests on function recoverERC20

    /// @notice Asserts {recoverERC20} rejects a zero token address with
    ///         {ZeroAddress}.
    /// @dev    Auth passes (pranked as ambassador); the zero-token guard
    ///         is the first check after the modifier.
    function test_recoverERC20_tokenAddressIsZeroAddress() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);

        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.ZeroAddress.selector);
        account.recoverERC20(address(0), users.ambassador, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {recoverERC20} is gated by `onlyAmbassador`.
    /// @dev    Pranks as `users.attacker` and expects {NotAnAmbassador}.
    function test_recoverERC20_whenNotCalledByAmbassador() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);

        vm.prank(users.attacker);
        vm.expectRevert(BLOKCAmbassadorAccount.NotAnAmbassador.selector);
        account.recoverERC20(address(blokc), users.ambassador, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {recoverERC20} refuses to recover $BLOKC itself —
    ///         the locked asset is never recoverable via this path.
    /// @dev    Reverts with {InvalidERC20Token} when the supplied token
    ///         equals the bound {token}. Pins the BIP-002 §11.4 rule that
    ///         only foreign ERC20s may be swept.
    function test_recoverERC20_revert_if_whenERCTokenIs_A_BLOKC_Token() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.InvalidERC20Token.selector);
        account.recoverERC20(address(blokc), users.ambassador, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {recoverERC20} reverts with {InsufficientBalance}
    ///         when the requested amount exceeds the account's balance
    ///         of the foreign token.
    /// @dev    Deploys a fresh `MockERC20`, mints `DEFAULT_FUND_AMOUNT`
    ///         into the account, **then** arms the prank — order matters,
    ///         because `new MockERC20(...)` would otherwise consume the
    ///         prank before the real call.
    function test_recoverERC20_revert_if_amountExceedsBalance() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);

        MockERC20 token = new MockERC20("Test Token", "TEST");

        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);
        vm.prank(users.ambassador);

        vm.expectRevert(BLOKCAmbassadorAccount.InsufficientBalance.selector);
        account.recoverERC20(address(token), users.ambassador, Constants.DEFAULT_FUND_AMOUNT + 1);
    }

    /// @notice Asserts {recoverERC20} rejects a zero recipient with
    ///         {ZeroAddress}.
    /// @dev    Auth + token + non-$BLOKC guards all pass; the zero-recipient
    ///         check is the next guard.
    function test_recoverERC20_revertWhen_RecipientIsZero() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        MockERC20 token = new MockERC20("Test Token", "TEST");
        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.ZeroAddress.selector);
        account.recoverERC20(address(token), address(0), Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {recoverERC20} rejects a zero amount with {ZeroAmount}.
    function test_recoverERC20_revertWhen_AmountIsZero() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        MockERC20 token = new MockERC20("Test Token", "TEST");
        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.ZeroAmount.selector);
        account.recoverERC20(address(token), users.recipient, 0);
    }

    /// @notice Happy-path: recovering a foreign ERC20 transfers it to the
    ///         chosen recipient, decrements the account's balance, and
    ///         emits {NonBLOKCTokensRecovered}.
    /// @dev    Recovery is allowed before unlock — the lock only protects
    ///         $BLOKC. Asserts both sides of the transfer plus the event.
    function test_recoverERC20_transfersAndEmits() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        MockERC20 token = new MockERC20("Test Token", "TEST");
        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);
        uint256 amount = 400_000e18;

        vm.expectEmit(true, true, false, true, address(account));
        emit NonBLOKCTokensRecovered(address(token), users.recipient, amount);

        vm.prank(users.ambassador);
        account.recoverERC20(address(token), users.recipient, amount);

        assertEq(token.balanceOf(users.recipient), amount, "recipient received foreign token");
        assertEq(
            token.balanceOf(address(account)), Constants.DEFAULT_FUND_AMOUNT - amount, "account foreign balance reduced"
        );
    }

    /// @notice Asserts {recoverERC20} can sweep a foreign token even after
    ///         unlock, and that doing so never touches the $BLOKC balance.
    /// @dev    Funds the account with both $BLOKC and a foreign token, then
    ///         recovers the full foreign balance and checks $BLOKC is intact.
    function test_recoverERC20_doesNotTouchBLOKC() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        MockERC20 token = new MockERC20("Test Token", "TEST");
        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);
        _warpPastUnlock();

        vm.prank(users.ambassador);
        account.recoverERC20(address(token), users.recipient, Constants.DEFAULT_FUND_AMOUNT);

        assertEq(token.balanceOf(address(account)), 0, "foreign token fully recovered");
        assertEq(blokc.balanceOf(address(account)), Constants.DEFAULT_FUND_AMOUNT, "BLOKC balance untouched");
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAW
    //////////////////////////////////////////////////////////////*/

    //tests for function withdraw

    /// @notice Asserts {withdraw} is gated by `onlyAmbassador`.
    /// @dev    Pranks as `users.attacker` and expects {NotAnAmbassador}.
    function test_withdraw_revert_if_calledByNonAmbassador() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        vm.prank(users.attacker);
        _warpPastUnlock();
        vm.expectRevert(BLOKCAmbassadorAccount.NotAnAmbassador.selector);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {withdraw} reverts with {NoTimelineUnlockedYet}
    ///         when called well before the unlock timestamp.
    /// @dev    Time remains at `Constants.START_TIMESTAMP` (1 year pre-unlock).
    function test_withdraw_revert_if_calledBeforeUnlock() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.NoTimelineUnlockedYet.selector);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT);
    }

    //boundary tests

    /// @notice Boundary: asserts {withdraw} still reverts at exactly one
    ///         second before unlock.
    /// @dev    Uses `_warpToJustBeforeUnlock()` (= `UNLOCK_TIMESTAMP - 1`).
    ///         Pins the strict `>=` predicate inside
    ///         {onlyAfterUnlockTimestamp}.
    function test_withdraw_revert_if_only_OneSecond_Left_BeforeUnlock() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        vm.prank(users.ambassador);

        _warpToJustBeforeUnlock();
        vm.expectRevert(BLOKCAmbassadorAccount.NoTimelineUnlockedYet.selector);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Happy-path: a full withdrawal works one day past unlock.
    /// @dev    Uses `_warpPastUnlock()` (= `UNLOCK_TIMESTAMP + 1 day`).
    ///         Asserts the {Withdrawn} event, the recipient credit and the
    ///         drained account balance, so a minting regression is caught.
    function test_withdraw_succeeds_if_only_OneDay_After_Unlock() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpPastUnlock();

        vm.expectEmit(true, false, false, true, address(account));
        emit Withdrawn(users.recipient, Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.ambassador);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT);

        assertEq(blokc.balanceOf(users.recipient), Constants.DEFAULT_FUND_AMOUNT, "recipient received amount");
        assertEq(blokc.balanceOf(address(account)), 0, "account fully drained");
    }

    //at unlock second
    /// @notice Boundary: asserts {withdraw} succeeds at exactly the unlock
    ///         second (`block.timestamp == UNLOCK_TIMESTAMP`).
    /// @dev    The lock predicate is `unlockTimestamp > block.timestamp`,
    ///         so equality is intentionally on the unlocked side.
    function test_withdraw_succeedsExactly_AtUnlockSecond() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpToUnlock();

        vm.expectEmit(true, false, false, true, address(account));
        emit Withdrawn(users.ambassador, Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.ambassador);
        account.withdraw(users.ambassador, Constants.DEFAULT_FUND_AMOUNT);

        assertEq(blokc.balanceOf(users.ambassador), Constants.DEFAULT_FUND_AMOUNT, "recipient received amount");
        assertEq(blokc.balanceOf(address(account)), 0, "account fully drained");
    }

    /// @notice Asserts {withdraw} rejects a zero recipient with
    ///         {ZeroAddress}.
    /// @dev    Auth + time gates both pass; the zero-recipient check is
    ///         the next guard inside {withdraw}.
    function test_withdraw_revertWhen_RecipientIsZero() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpPastUnlock();
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.ZeroAddress.selector);
        account.withdraw(address(0), 1);
    }

    /// @notice Asserts {withdraw} rejects a zero amount with {ZeroAmount}.
    function test_withdraw_revertWhen_AmountIsZero() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpPastUnlock();
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.ZeroAmount.selector);
        account.withdraw(users.recipient, 0);
    }

    /// @notice Asserts {withdraw} reverts with {InsufficientBalance} when
    ///         the account holds no $BLOKC at all.
    /// @dev    Uses `_createAccount` (not `_fundedAccount`) to skip the
    ///         mint step, so the account's $BLOKC balance is zero.
    function test_withdraw_revertWhen_BalanceIsZero() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        _warpPastUnlock();
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.InsufficientBalance.selector);
        account.withdraw(users.recipient, 1);
    }

    /// @notice Asserts {withdraw} reverts with {InsufficientBalance} when
    ///         the requested amount exceeds the held balance.
    function test_withdraw_revertWhen_AmountExceedsBalance() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpPastUnlock();
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.InsufficientBalance.selector);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT + 1);
    }

    /// @notice Happy-path: a partial withdrawal transfers the requested
    ///         amount to the recipient and decrements the account's
    ///         balance accordingly.
    /// @dev    Side-effect assertions cover both sides of the transfer.
    function test_withdraw_transfers() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpPastUnlock();
        uint256 amount = 250_00e18;

        vm.expectEmit(true, false, false, true, address(account));
        emit Withdrawn(users.recipient, amount);

        vm.prank(users.ambassador);
        account.withdraw(users.recipient, amount);

        assertEq(blokc.balanceOf(users.recipient), amount, "recipient received amount");
        assertEq(blokc.balanceOf(address(account)), Constants.DEFAULT_FUND_AMOUNT - amount, "account balance decreased");
    }

    /// @notice Asserts {withdraw} accepts **any** non-zero recipient, not
    ///         just the ambassador themselves.
    /// @dev    Sends to `users.goodSamaritan` to make the "arbitrary
    ///         recipient" property explicit.
    function test_withdraw_canSendToAnyNonZeroRecipient() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpPastUnlock();

        vm.expectEmit(true, false, false, true, address(account));
        emit Withdrawn(users.goodSamaritan, 1e18);

        vm.prank(users.ambassador);
        account.withdraw(users.goodSamaritan, 1e18);

        assertEq(blokc.balanceOf(users.goodSamaritan), 1e18, "recipient received amount");
        assertEq(blokc.balanceOf(address(account)), Constants.DEFAULT_FUND_AMOUNT - 1e18, "account balance decreased");
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW_TOKENS_ALL
    //////////////////////////////////////////////////////////////*/

    //tests for function withdrawTokensAll

    /// @notice Asserts {withdrawTokensAll} is gated by `onlyAmbassador`.
    /// @dev    Pranks as `users.attacker` and expects {NotAnAmbassador}.
    function test_withdrawTokensAll_revertWhen_CallerIsNotAmbassador() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpPastUnlock();
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCAmbassadorAccount.NotAnAmbassador.selector);
        account.withdrawTokensAll();
    }

    /// @notice Asserts {withdrawTokensAll} reverts with {NoTimelineUnlockedYet}
    ///         before unlock.
    function test_withdrawTokensAll_revertWhen_StillLocked() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.NoTimelineUnlockedYet.selector);
        account.withdrawTokensAll();
    }

    /// @notice Asserts {withdrawTokensAll} reverts with {InsufficientBalance}
    ///         when the account holds no $BLOKC.
    /// @dev    Uses `_createAccount` (no mint) so the balance is zero.
    function test_withdrawTokensAll_revertWhen_BalanceIsZero() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        _warpPastUnlock();
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.InsufficientBalance.selector);
        account.withdrawTokensAll();
    }

    /// @notice Boundary: asserts {withdrawTokensAll} succeeds at exactly the
    ///         unlock second.
    /// @dev    Asserts the full balance is delivered to the ambassador.
    function test_withdrawTokensAll_succeedsExactlyAtUnlockSecond() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpToUnlock();
        vm.prank(users.ambassador);
        account.withdrawTokensAll();
        assertEq(blokc.balanceOf(users.ambassador), Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Happy-path: sweeps the entire $BLOKC balance to the ambassador
    ///         and leaves the account empty.
    /// @dev    Asserts both sides of the transfer.
    function test_withdrawTokensAll_sweepsFullBalance() public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _warpPastUnlock();

        vm.expectEmit(true, false, false, true, address(account));
        emit AllTokensWithdrawn(users.ambassador, Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.ambassador);
        account.withdrawTokensAll();

        assertEq(blokc.balanceOf(address(account)), 0);
        assertEq(blokc.balanceOf(users.ambassador), Constants.DEFAULT_FUND_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {balanceOf} mirrors the account's live $BLOKC balance
    ///         before and after a funding mint.
    function test_view_balanceOf_tracksHeldBLOKC() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        assertEq(account.balanceOf(), 0, "starts empty");

        _fundAccount(address(account));
        assertEq(account.balanceOf(), Constants.DEFAULT_FUND_AMOUNT, "reflects minted balance");
    }

    /// @notice Asserts {getUnlockTimestamp} returns the value bound at init.
    function test_view_getUnlockTimestamp_returnsBoundValue() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        assertEq(account.getUnlockTimestamp(), Constants.UNLOCK_TIMESTAMP);
        assertEq(account.getUnlockTimestamp(), account.unlockTimestamp());
    }

    /// @notice Asserts {isUnlocked} is false before unlock, false at one
    ///         second before, and true at exactly the unlock second.
    /// @dev    Pins the `>=` predicate on both sides of the boundary.
    function test_view_isUnlocked_acrossBoundary() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        assertFalse(account.isUnlocked(), "locked one year out");

        _warpToJustBeforeUnlock();
        assertFalse(account.isUnlocked(), "locked one second before");

        _warpToUnlock();
        assertTrue(account.isUnlocked(), "unlocked at the unlock second");
    }

    /// @notice Asserts {timeUntilUnlock} counts down before unlock and
    ///         returns 0 from the unlock second onward.
    /// @dev    Covers both branches of the ternary in the contract.
    function test_view_timeUntilUnlock_bothBranches() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        assertEq(account.timeUntilUnlock(), uint256(Constants.UNLOCK_TIMESTAMP) - block.timestamp, "counts down");

        _warpToJustBeforeUnlock();
        assertEq(account.timeUntilUnlock(), 1, "one second remaining");

        _warpToUnlock();
        assertEq(account.timeUntilUnlock(), 0, "zero at unlock");

        _warpPastUnlock();
        assertEq(account.timeUntilUnlock(), 0, "stays zero past unlock");
    }
}
