// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "test/utils/BaseTest.sol";
import {BLOKCAmbassadorAccount} from "src/contracts/BLOKCAmbassadorAccount.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Constants} from "test/utils/Constants.sol";

/// @title  AccountFuzzTest
/// @notice Property/fuzz tests for {BLOKCAmbassadorAccount}. Where the unit
///         tests pin specific points, these sweep the argument and time
///         spaces: arbitrary withdrawal amounts and recipients, the unlock
///         boundary at arbitrary timestamps, and multi-step partial
///         withdrawals that must still conserve the balance.
contract AccountFuzzTest is BaseTest {
    /// @notice Restricts a fuzzed recipient to a "clean" external address:
    ///         non-zero, not a precompile, and not the account itself (a
    ///         self-transfer would make balance assertions trivial).
    function _assumeCleanRecipient(address to, address account) internal pure {
        vm.assume(to != address(0));
        vm.assume(to != account);
        vm.assume(uint160(to) > 0x0a);
    }

    /// @notice For any valid amount and recipient, a post-unlock withdrawal
    ///         moves exactly `amount` to the recipient and decrements the
    ///         account by exactly `amount`.
    function testFuzz_withdraw_movesExactAmount(uint256 amount, address to) public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _assumeCleanRecipient(to, address(account));
        amount = bound(amount, 1, Constants.DEFAULT_FUND_AMOUNT);

        _warpPastUnlock();
        uint256 toBefore = blokc.balanceOf(to);

        vm.prank(users.ambassador);
        account.withdraw(to, amount);

        assertEq(blokc.balanceOf(to), toBefore + amount, "recipient credited exactly");
        assertEq(account.balanceOf(), Constants.DEFAULT_FUND_AMOUNT - amount, "account debited exactly");
    }

    /// @notice For any amount strictly greater than the held balance, a
    ///         post-unlock withdrawal reverts with {InsufficientBalance}.
    function testFuzz_withdraw_revertsAboveBalance(uint256 amount) public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        amount = bound(amount, Constants.DEFAULT_FUND_AMOUNT + 1, type(uint256).max);

        _warpPastUnlock();
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.InsufficientBalance.selector);
        account.withdraw(users.recipient, amount);
    }

    /// @notice The unlock predicate is exactly `block.timestamp >= unlock`
    ///         for any timestamp: {isUnlocked} agrees with it, and a
    ///         withdrawal succeeds iff unlocked (else reverts with
    ///         {NoTimelineUnlockedYet}).
    function testFuzz_unlockBoundary_isExact(uint64 ts) public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        ts = uint64(bound(ts, 1, type(uint64).max));
        vm.warp(ts);

        bool unlocked = ts >= Constants.UNLOCK_TIMESTAMP;
        assertEq(account.isUnlocked(), unlocked, "isUnlocked must match >= predicate");

        vm.prank(users.ambassador);
        if (unlocked) {
            account.withdraw(users.recipient, 1);
            assertEq(blokc.balanceOf(users.recipient), 1);
        } else {
            vm.expectRevert(BLOKCAmbassadorAccount.NoTimelineUnlockedYet.selector);
            account.withdraw(users.recipient, 1);
        }
    }

    /// @notice A sequence of partial withdrawals never lets the ambassador
    ///         remove more than the balance: two withdrawals whose sum
    ///         exceeds the balance must have the second revert, and the
    ///         conserved total out + remaining == initial balance.
    function testFuzz_partialWithdrawals_conserveBalance(uint256 a, uint256 b) public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        uint256 total = Constants.DEFAULT_FUND_AMOUNT;
        a = bound(a, 1, total);
        b = bound(b, 1, total);

        _warpPastUnlock();

        vm.prank(users.ambassador);
        account.withdraw(users.recipient, a);
        assertEq(account.balanceOf(), total - a, "remaining after first withdrawal");

        vm.prank(users.ambassador);
        if (b <= total - a) {
            account.withdraw(users.recipient, b);
            assertEq(blokc.balanceOf(users.recipient), a + b, "recipient holds the sum");
            assertEq(account.balanceOf(), total - a - b, "balance conserved");
        } else {
            vm.expectRevert(BLOKCAmbassadorAccount.InsufficientBalance.selector);
            account.withdraw(users.recipient, b);
        }
    }

    /// @notice For any valid amount and recipient, recovering a foreign
    ///         token moves exactly `amount` and never touches $BLOKC.
    function testFuzz_recoverERC20_movesExactAmount(uint256 amount, address to) public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        _assumeCleanRecipient(to, address(account));

        MockERC20 foreign = new MockERC20("Foreign", "FRGN");
        foreign.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);
        amount = bound(amount, 1, Constants.DEFAULT_FUND_AMOUNT);

        vm.prank(users.ambassador);
        account.recoverERC20(address(foreign), to, amount);

        assertEq(foreign.balanceOf(to), amount, "foreign token moved exactly");
        assertEq(account.balanceOf(), Constants.DEFAULT_FUND_AMOUNT, "BLOKC untouched by recovery");
    }

    /// @notice Re-delegating to any non-zero delegatee always routes the
    ///         account's full voting power to that delegatee.
    function testFuzz_reDelegate_routesAllVotes(address to) public {
        BLOKCAmbassadorAccount account = _fundedAccount();
        vm.assume(to != address(0));

        vm.prank(users.ambassador);
        account.reDelegate(to);

        assertEq(blokc.delegates(address(account)), to, "delegatee set");
        assertEq(blokc.getVotes(to), Constants.DEFAULT_FUND_AMOUNT, "delegatee holds full vote weight");
    }
}
