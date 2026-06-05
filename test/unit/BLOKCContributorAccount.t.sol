// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "test/utils/BaseTest.sol";
import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Constants} from "test/utils/Constants.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title  BLOKCContributorAccountTest
/// @notice Unit tests for {BLOKCContributorAccount}.
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
contract BLOKCContributorAccountTest is BaseTest {
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
    function _clone() internal returns (BLOKCContributorAccount clone) {
        clone = BLOKCContributorAccount(Clones.clone(address(implementation)));
        vm.label(address(clone), "Clone");
        return clone;
    }

    /// @notice Deploys a clone via {_clone} and initializes it with the
    ///         canonical (`users.contributor`, `blokc`, `UNLOCK_TIMESTAMP`)
    ///         triple.
    /// @dev    Convenience wrapper for tests that need an already-init'd
    ///         clone (e.g. the double-initialize check). Does NOT mint
    ///         any $BLOKC into the clone — use {_fundedAccount} from
    ///         {BaseTest} for that.
    /// @return clone An initialized clone bound to `users.contributor`.
    function _initializedClone() internal returns (BLOKCContributorAccount clone) {
        clone = _clone();
        clone.initialize(users.contributor, address(blokc), Constants.UNLOCK_TIMESTAMP);
        return clone;
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    //test the initialize function
    /// @notice Asserts the three zero-argument guards in {initialize}:
    ///         zero contributor → {ZeroAddress}, zero token → {ZeroAddress},
    ///         zero unlock timestamp → {ZeroTimestamp}.
    /// @dev    All three sub-cases run against the same uninitialized
    ///         clone — since each `initialize` call reverts, the clone
    ///         stays uninitialized and can be reused for the next case.
    function test_initialize_zeroAddress() public {
        //simple zero address overall initialize tests
        BLOKCContributorAccount clone = _clone();
        vm.expectRevert(BLOKCContributorAccount.ZeroAddress.selector);
        clone.initialize(address(0), address(blokc), Constants.UNLOCK_TIMESTAMP);

        //revert if the token is the zero address
        vm.expectRevert(BLOKCContributorAccount.ZeroAddress.selector);
        clone.initialize(users.contributor, address(0), Constants.UNLOCK_TIMESTAMP);

        //revert if the unlock timestamp is zero
        vm.expectRevert(BLOKCContributorAccount.ZeroTimestamp.selector);
        clone.initialize(users.contributor, address(blokc), 0);
    }

    /// @notice Asserts that a second {initialize} call on an already
    ///         initialized clone reverts with OZ's
    ///         {Initializable.InvalidInitialization}.
    /// @dev    The error lives on OpenZeppelin's {Initializable}, not on
    ///         {BLOKCContributorAccount} itself — that's why the selector
    ///         is namespaced to `Initializable`.
    function test_initialze_twiceInitializeCheck() public {
        BLOKCContributorAccount clone = _initializedClone();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(users.contributor, address(blokc), Constants.UNLOCK_TIMESTAMP);
    }

    /// @notice Asserts that the **implementation** itself can never be
    ///         initialized directly — only its clones can.
    /// @dev    The implementation's constructor calls
    ///         `_disableInitializers()`, which marks it as already
    ///         initialized; any direct {initialize} call therefore
    ///         reverts with {Initializable.InvalidInitialization}.
    function test_initialize_revertWhen_InitializedCalledOn_Implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);

        implementation.initialize(users.contributor, address(blokc), Constants.UNLOCK_TIMESTAMP);
    }

    /// @notice Happy-path: a raw clone initialized directly persists all
    ///         three bound values, emits {Initialized}, and delegates its
    ///         voting power to the contributor.
    /// @dev    Exercises {initialize} outside the factory so the event and
    ///         the post-state are asserted independently of the create flow.
    ///         The {Initialized} event is emitted before the external
    ///         `delegate` call, so it is checked against the clone address.
    function test_initialize_setsStateAndEmitsAndDelegates() public {
        BLOKCContributorAccount clone = _clone();

        vm.expectEmit(true, true, false, true, address(clone));
        emit Initialized(users.contributor, address(blokc), Constants.UNLOCK_TIMESTAMP);

        clone.initialize(users.contributor, address(blokc), Constants.UNLOCK_TIMESTAMP);

        assertEq(clone.contributor(), users.contributor, "contributor stored");
        assertEq(clone.token(), address(blokc), "token stored");
        assertEq(clone.unlockTimestamp(), Constants.UNLOCK_TIMESTAMP, "unlock stored");
        assertEq(blokc.delegates(address(clone)), users.contributor, "voting power delegated to contributor");
    }

    /*//////////////////////////////////////////////////////////////
                              REDELEGATE
    //////////////////////////////////////////////////////////////*/

    //tests on redelegate
    /// @notice Asserts {reDelegate} is gated by `onlyContributor`.
    /// @dev    Pranks as `users.attacker` and expects {NotAContributor}.
    function test_redelegate_revertWhen_CalledByNonContributor() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCContributorAccount.NotAContributor.selector);
        account.reDelegate(users.delegatee);
    }

    /// @notice Asserts {reDelegate} rejects a zero-address delegatee.
    /// @dev    Pranks as the contributor so the auth gate passes; the
    ///         internal `_delegate` zero-address guard should then fire
    ///         with {ZeroAddress}.
    function test_redelegate_revertWhen_DelegeteeIsZeroAddress() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.ZeroAddress.selector);
        account.reDelegate(address(0));
    }

    /// @notice Happy-path: re-delegating moves the account's voting
    ///         power from the contributor to the new delegatee.
    /// @dev    Pre-condition: account is funded, so `getVotes(contributor)`
    ///         is non-zero on entry. After {reDelegate}:
    ///           - `delegates(account)` points to the new delegatee,
    ///           - contributor's vote count drops to zero,
    ///           - the delegatee receives the full balance as vote power.
    function test_redelegate_movesVotingPower() public {
        BLOKCContributorAccount account = _fundedAccount();
        assertEq(blokc.getVotes(users.contributor), Constants.DEFAULT_FUND_AMOUNT);

        vm.expectEmit(true, false, false, true, address(account));
        emit Redelegated(users.delegatee);

        vm.prank(users.contributor);
        account.reDelegate(users.delegatee);

        assertEq(blokc.delegates(address(account)), users.delegatee, "delegate updated");
        assertEq(blokc.getVotes(users.contributor), 0, "contributor votes cleared");
        assertEq(blokc.getVotes(users.delegatee), Constants.DEFAULT_FUND_AMOUNT, "delegatee receives votes");
    }

    /// @notice Asserts {reDelegate} keeps working **after** unlock — the
    ///         lock applies to fund movement, not to governance routing.
    /// @dev    Same vote-power assertions as the happy path, but executed
    ///         after `_warpPastUnlock()`. Pins the BIP-002 rule that
    ///         delegation is unrestricted across the entire account lifetime.
    function test_redelegate_worksAfterUnlock() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpPastUnlock();

        vm.prank(users.contributor);

        account.reDelegate(users.delegatee);

        assertEq(blokc.delegates(address(account)), users.delegatee, "delegate updated");
        assertEq(blokc.getVotes(users.contributor), 0, "contributor votes cleared");
        assertEq(blokc.getVotes(users.delegatee), Constants.DEFAULT_FUND_AMOUNT, "delegatee receives votes");
    }

    /*//////////////////////////////////////////////////////////////
                              RECOVER_ERC20
    //////////////////////////////////////////////////////////////*/

    //tests on function recoverERC20

    /// @notice Asserts {recoverERC20} rejects a zero token address with
    ///         {ZeroAddress}.
    /// @dev    Auth passes (pranked as contributor); the zero-token guard
    ///         is the first check after the modifier.
    function test_recoverERC20_tokenAddressIsZeroAddress() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);

        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.ZeroAddress.selector);
        account.recoverERC20(address(0), users.contributor, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {recoverERC20} is gated by `onlyContributor`.
    /// @dev    Pranks as `users.attacker` and expects {NotAContributor}.
    function test_recoverERC20_whenNotCalledByContributor() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);

        vm.prank(users.attacker);
        vm.expectRevert(BLOKCContributorAccount.NotAContributor.selector);
        account.recoverERC20(address(blokc), users.contributor, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {recoverERC20} refuses to recover $BLOKC itself —
    ///         the locked asset is never recoverable via this path.
    /// @dev    Reverts with {InvalidERC20Token} when the supplied token
    ///         equals the bound {token}. Pins the BIP-002 §11.4 rule that
    ///         only foreign ERC20s may be swept.
    function test_recoverERC20_revert_if_whenERCTokenIs_A_BLOKC_Token() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.InvalidERC20Token.selector);
        account.recoverERC20(address(blokc), users.contributor, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {recoverERC20} reverts with {InsufficientBalance}
    ///         when the requested amount exceeds the account's balance
    ///         of the foreign token.
    /// @dev    Deploys a fresh `MockERC20`, mints `DEFAULT_FUND_AMOUNT`
    ///         into the account, **then** arms the prank — order matters,
    ///         because `new MockERC20(...)` would otherwise consume the
    ///         prank before the real call.
    function test_recoverERC20_revert_if_amountExceedsBalance() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);

        MockERC20 token = new MockERC20("Test Token", "TEST");

        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);
        vm.prank(users.contributor);

        vm.expectRevert(BLOKCContributorAccount.InsufficientBalance.selector);
        account.recoverERC20(address(token), users.contributor, Constants.DEFAULT_FUND_AMOUNT + 1);
    }

    /// @notice Asserts {recoverERC20} rejects a zero recipient with
    ///         {ZeroAddress}.
    /// @dev    Auth + token + non-$BLOKC guards all pass; the zero-recipient
    ///         check is the next guard.
    function test_recoverERC20_revertWhen_RecipientIsZero() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        MockERC20 token = new MockERC20("Test Token", "TEST");
        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.ZeroAddress.selector);
        account.recoverERC20(address(token), address(0), Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {recoverERC20} rejects a zero amount with {ZeroAmount}.
    function test_recoverERC20_revertWhen_AmountIsZero() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        MockERC20 token = new MockERC20("Test Token", "TEST");
        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.ZeroAmount.selector);
        account.recoverERC20(address(token), users.recipient, 0);
    }

    /// @notice Happy-path: recovering a foreign ERC20 transfers it to the
    ///         chosen recipient, decrements the account's balance, and
    ///         emits {NonBLOKCTokensRecovered}.
    /// @dev    Recovery is allowed before unlock — the lock only protects
    ///         $BLOKC. Asserts both sides of the transfer plus the event.
    function test_recoverERC20_transfersAndEmits() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        MockERC20 token = new MockERC20("Test Token", "TEST");
        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);
        uint256 amount = 400_000e18;

        vm.expectEmit(true, true, false, true, address(account));
        emit NonBLOKCTokensRecovered(address(token), users.recipient, amount);

        vm.prank(users.contributor);
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
        BLOKCContributorAccount account = _fundedAccount();
        MockERC20 token = new MockERC20("Test Token", "TEST");
        token.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);
        _warpPastUnlock();

        vm.prank(users.contributor);
        account.recoverERC20(address(token), users.recipient, Constants.DEFAULT_FUND_AMOUNT);

        assertEq(token.balanceOf(address(account)), 0, "foreign token fully recovered");
        assertEq(blokc.balanceOf(address(account)), Constants.DEFAULT_FUND_AMOUNT, "BLOKC balance untouched");
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAW
    //////////////////////////////////////////////////////////////*/

    //tests for function withdraw

    /// @notice Asserts {withdraw} is gated by `onlyContributor`.
    /// @dev    Pranks as `users.attacker` and expects {NotAContributor}.
    function test_withdraw_revert_if_calledByNonContributor() public {
        BLOKCContributorAccount account = _fundedAccount();
        vm.prank(users.attacker);
        _warpPastUnlock();
        vm.expectRevert(BLOKCContributorAccount.NotAContributor.selector);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts {withdraw} reverts with {NoTimelineUnlockedYet}
    ///         when called well before the unlock timestamp.
    /// @dev    Time remains at `Constants.START_TIMESTAMP` (1 year pre-unlock).
    function test_withdraw_revert_if_calledBeforeUnlock() public {
        BLOKCContributorAccount account = _fundedAccount();
        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.NoTimelineUnlockedYet.selector);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT);
    }

    //boundary tests

    /// @notice Boundary: asserts {withdraw} still reverts at exactly one
    ///         second before unlock.
    /// @dev    Uses `_warpToJustBeforeUnlock()` (= `UNLOCK_TIMESTAMP - 1`).
    ///         Pins the strict `>=` predicate inside
    ///         {onlyAfterUnlockTimestamp}.
    function test_withdraw_revert_if_only_OneSecond_Left_BeforeUnlock() public {
        BLOKCContributorAccount account = _fundedAccount();
        vm.prank(users.contributor);

        _warpToJustBeforeUnlock();
        vm.expectRevert(BLOKCContributorAccount.NoTimelineUnlockedYet.selector);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Happy-path: a full withdrawal works one day past unlock.
    /// @dev    Uses `_warpPastUnlock()` (= `UNLOCK_TIMESTAMP + 1 day`).
    ///         Asserts the {Withdrawn} event, the recipient credit and the
    ///         drained account balance, so a minting regression is caught.
    function test_withdraw_succeeds_if_only_OneDay_After_Unlock() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpPastUnlock();

        vm.expectEmit(true, false, false, true, address(account));
        emit Withdrawn(users.recipient, Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.contributor);
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
        BLOKCContributorAccount account = _fundedAccount();
        _warpToUnlock();

        vm.expectEmit(true, false, false, true, address(account));
        emit Withdrawn(users.contributor, Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.contributor);
        account.withdraw(users.contributor, Constants.DEFAULT_FUND_AMOUNT);

        assertEq(blokc.balanceOf(users.contributor), Constants.DEFAULT_FUND_AMOUNT, "recipient received amount");
        assertEq(blokc.balanceOf(address(account)), 0, "account fully drained");
    }

    /// @notice Asserts {withdraw} rejects a zero recipient with
    ///         {ZeroAddress}.
    /// @dev    Auth + time gates both pass; the zero-recipient check is
    ///         the next guard inside {withdraw}.
    function test_withdraw_revertWhen_RecipientIsZero() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpPastUnlock();
        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.ZeroAddress.selector);
        account.withdraw(address(0), 1);
    }

    /// @notice Asserts {withdraw} rejects a zero amount with {ZeroAmount}.
    function test_withdraw_revertWhen_AmountIsZero() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpPastUnlock();
        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.ZeroAmount.selector);
        account.withdraw(users.recipient, 0);
    }

    /// @notice Asserts {withdraw} reverts with {InsufficientBalance} when
    ///         the account holds no $BLOKC at all.
    /// @dev    Uses `_createAccount` (not `_fundedAccount`) to skip the
    ///         mint step, so the account's $BLOKC balance is zero.
    function test_withdraw_revertWhen_BalanceIsZero() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        _warpPastUnlock();
        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.InsufficientBalance.selector);
        account.withdraw(users.recipient, 1);
    }

    /// @notice Asserts {withdraw} reverts with {InsufficientBalance} when
    ///         the requested amount exceeds the held balance.
    function test_withdraw_revertWhen_AmountExceedsBalance() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpPastUnlock();
        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.InsufficientBalance.selector);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT + 1);
    }

    /// @notice Happy-path: a partial withdrawal transfers the requested
    ///         amount to the recipient and decrements the account's
    ///         balance accordingly.
    /// @dev    Side-effect assertions cover both sides of the transfer.
    function test_withdraw_transfers() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpPastUnlock();
        uint256 amount = 250_00e18;

        vm.expectEmit(true, false, false, true, address(account));
        emit Withdrawn(users.recipient, amount);

        vm.prank(users.contributor);
        account.withdraw(users.recipient, amount);

        assertEq(blokc.balanceOf(users.recipient), amount, "recipient received amount");
        assertEq(blokc.balanceOf(address(account)), Constants.DEFAULT_FUND_AMOUNT - amount, "account balance decreased");
    }

    /// @notice Asserts {withdraw} accepts **any** non-zero recipient, not
    ///         just the contributor themselves.
    /// @dev    Sends to `users.goodSamaritan` to make the "arbitrary
    ///         recipient" property explicit.
    function test_withdraw_canSendToAnyNonZeroRecipient() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpPastUnlock();

        vm.expectEmit(true, false, false, true, address(account));
        emit Withdrawn(users.goodSamaritan, 1e18);

        vm.prank(users.contributor);
        account.withdraw(users.goodSamaritan, 1e18);

        assertEq(blokc.balanceOf(users.goodSamaritan), 1e18, "recipient received amount");
        assertEq(blokc.balanceOf(address(account)), Constants.DEFAULT_FUND_AMOUNT - 1e18, "account balance decreased");
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW_TOKENS_ALL
    //////////////////////////////////////////////////////////////*/

    //tests for function withdrawTokensAll

    /// @notice Asserts {withdrawTokensAll} is gated by `onlyContributor`.
    /// @dev    Pranks as `users.attacker` and expects {NotAContributor}.
    function test_withdrawTokensAll_revertWhen_CallerIsNotContributor() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpPastUnlock();
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCContributorAccount.NotAContributor.selector);
        account.withdrawTokensAll();
    }

    /// @notice Asserts {withdrawTokensAll} reverts with {NoTimelineUnlockedYet}
    ///         before unlock.
    function test_withdrawTokensAll_revertWhen_StillLocked() public {
        BLOKCContributorAccount account = _fundedAccount();
        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.NoTimelineUnlockedYet.selector);
        account.withdrawTokensAll();
    }

    /// @notice Asserts {withdrawTokensAll} reverts with {InsufficientBalance}
    ///         when the account holds no $BLOKC.
    /// @dev    Uses `_createAccount` (no mint) so the balance is zero.
    function test_withdrawTokensAll_revertWhen_BalanceIsZero() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        _warpPastUnlock();
        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.InsufficientBalance.selector);
        account.withdrawTokensAll();
    }

    /// @notice Boundary: asserts {withdrawTokensAll} succeeds at exactly the
    ///         unlock second.
    /// @dev    Asserts the full balance is delivered to the contributor.
    function test_withdrawTokensAll_succeedsExactlyAtUnlockSecond() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpToUnlock();
        vm.prank(users.contributor);
        account.withdrawTokensAll();
        assertEq(blokc.balanceOf(users.contributor), Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Happy-path: sweeps the entire $BLOKC balance to the contributor
    ///         and leaves the account empty.
    /// @dev    Asserts both sides of the transfer.
    function test_withdrawTokensAll_sweepsFullBalance() public {
        BLOKCContributorAccount account = _fundedAccount();
        _warpPastUnlock();

        vm.expectEmit(true, false, false, true, address(account));
        emit AllTokensWithdrawn(users.contributor, Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.contributor);
        account.withdrawTokensAll();

        assertEq(blokc.balanceOf(address(account)), 0);
        assertEq(blokc.balanceOf(users.contributor), Constants.DEFAULT_FUND_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {balanceOf} mirrors the account's live $BLOKC balance
    ///         before and after a funding mint.
    function test_view_balanceOf_tracksHeldBLOKC() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        assertEq(account.balanceOf(), 0, "starts empty");

        _fundAccount(address(account));
        assertEq(account.balanceOf(), Constants.DEFAULT_FUND_AMOUNT, "reflects minted balance");
    }

    /// @notice Asserts {getUnlockTimestamp} returns the value bound at init.
    function test_view_getUnlockTimestamp_returnsBoundValue() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
        assertEq(account.getUnlockTimestamp(), Constants.UNLOCK_TIMESTAMP);
        assertEq(account.getUnlockTimestamp(), account.unlockTimestamp());
    }

    /// @notice Asserts {isUnlocked} is false before unlock, false at one
    ///         second before, and true at exactly the unlock second.
    /// @dev    Pins the `>=` predicate on both sides of the boundary.
    function test_view_isUnlocked_acrossBoundary() public {
        BLOKCContributorAccount account = _createAccount(users.contributor);
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
        BLOKCContributorAccount account = _createAccount(users.contributor);
        assertEq(account.timeUntilUnlock(), uint256(Constants.UNLOCK_TIMESTAMP) - block.timestamp, "counts down");

        _warpToJustBeforeUnlock();
        assertEq(account.timeUntilUnlock(), 1, "one second remaining");

        _warpToUnlock();
        assertEq(account.timeUntilUnlock(), 0, "zero at unlock");

        _warpPastUnlock();
        assertEq(account.timeUntilUnlock(), 0, "stays zero past unlock");
    }
}
