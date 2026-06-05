// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";
import {MaliciousERC20} from "test/mocks/MaliciousERC20.sol";
import {MaliciousVotesToken} from "test/mocks/MaliciousVotesToken.sol";
import {ReentrantReDelegateToken} from "test/mocks/ReentrantReDelegateToken.sol";
import {Constants} from "test/utils/Constants.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  ReentrancyTest
/// @notice Integration tests that exercise the two adversarial mocks the
///         repo ships but never previously used:
///           - {MaliciousVotesToken} re-enters the factory from inside the
///             `delegate` callback fired during `initialize`.
///           - {MaliciousERC20} mis-behaves during `recoverERC20`'s
///             `safeTransfer` (returns false, reverts, or re-enters).
///
/// @dev    Neither {BLOKCContributorAccount} nor {BLOKCContributorFactory}
///         uses a `ReentrancyGuard`; their safety rests on (a) the
///         factory's checks-effects-interactions ordering (registry written
///         before `initialize`) and (b) `SafeERC20` + the `onlyContributor`
///         gate on `recoverERC20`. These tests pin both claims.
contract ReentrancyTest is BaseTest {
    bytes32 internal constant CREATED_SIG = keccak256("ContributorAccountCreated(address,address)");

    /*//////////////////////////////////////////////////////////////
                    FACTORY REENTRY VIA delegate()
    //////////////////////////////////////////////////////////////*/

    /// @notice Proves the factory's CEI ordering makes a reentrant
    ///         `createContributorAccount` during `initialize → delegate`
    ///         safe: the reentry hits the idempotent short-circuit, so the
    ///         account address is stable, the registry holds exactly one
    ///         entry, and exactly one `ContributorAccountCreated` fires.
    /// @dev    Deploys a fresh factory bound to {MaliciousVotesToken}; the
    ///         clone's `initialize` calls `delegate`, which re-enters the
    ///         factory for the same contributor.
    function test_factory_reentryViaDelegate_isIdempotent() public {
        MaliciousVotesToken evilVotes = new MaliciousVotesToken();
        BLOKCContributorFactory evilFactory =
            new BLOKCContributorFactory(address(evilVotes), address(implementation), Constants.UNLOCK_TIMESTAMP);

        evilVotes.arm(evilFactory, users.contributor);

        address predicted = evilFactory.predictContributorAccount(users.contributor);

        vm.recordLogs();
        vm.prank(users.contributor);
        address deployed = evilFactory.createContributorAccount(users.contributor);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The reentrant create returned the SAME address as the outer create.
        assertEq(evilVotes.reentryReturn(), deployed, "reentrant create returned same address");
        assertEq(deployed, predicted, "deployed at predicted address");
        assertEq(evilVotes.reentryDepth(), 1, "reentry actually occurred");

        // Registry grew by exactly one despite the reentry.
        assertEq(evilFactory.getAccountsLength(), 1, "exactly one account registered");
        assertEq(evilFactory.accountOf(users.contributor), deployed, "registry points at the account");

        // Exactly one ContributorAccountCreated across the whole call tree.
        uint256 created;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == CREATED_SIG) created++;
        }
        assertEq(created, 1, "exactly one ContributorAccountCreated emitted");
    }

    /*//////////////////////////////////////////////////////////////
                    reDelegate REENTRY VIA delegate()
    //////////////////////////////////////////////////////////////*/

    /// @notice Proves a malicious token cannot escalate through
    ///         `reDelegate`: `reDelegate → _delegate → token.delegate`
    ///         gives the token a callback, but re-entering
    ///         `account.reDelegate` from there runs with the token as
    ///         `msg.sender`, so the `onlyContributor` gate reverts the entire
    ///         call and the account's delegation is left untouched.
    /// @dev    Uses {ReentrantReDelegateToken}; armed AFTER creation so the
    ///         `initialize` delegate does not trigger the reentry. The outer
    ///         `reDelegate` is sent by the contributor (passes the gate), so
    ///         the only {NotAContributor} revert can come from the reentry.
    function test_reDelegate_reentrantToken_blockedByOnlyContributor() public {
        ReentrantReDelegateToken evilVotes = new ReentrantReDelegateToken();
        BLOKCContributorFactory evilFactory =
            new BLOKCContributorFactory(address(evilVotes), address(implementation), Constants.UNLOCK_TIMESTAMP);

        vm.prank(users.contributor);
        BLOKCContributorAccount account = BLOKCContributorAccount(evilFactory.createContributorAccount());

        // Account starts delegated to the contributor (set in initialize).
        assertEq(evilVotes.delegates(address(account)), users.contributor, "delegated to contributor on init");

        // Arm the reentry: token.delegate will re-enter account.reDelegate.
        evilVotes.arm(account, users.delegatee);

        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.NotAContributor.selector);
        account.reDelegate(users.delegatee);

        // Whole call reverted: delegation is unchanged, attacker gained nothing.
        assertEq(evilVotes.delegates(address(account)), users.contributor, "delegation unchanged after blocked reentry");
    }

    /*//////////////////////////////////////////////////////////////
                    recoverERC20 vs MISBEHAVING ERC20
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys an account and funds it with a fresh malicious token
    ///         in the requested mode, returning both.
    function _accountWithEvilToken(MaliciousERC20.Mode mode)
        internal
        returns (BLOKCContributorAccount account, MaliciousERC20 evil)
    {
        account = _createAccount(users.contributor);
        evil = new MaliciousERC20();
        evil.mint(address(account), Constants.DEFAULT_FUND_AMOUNT);
        evil.setMode(mode);
    }

    /// @notice Asserts `recoverERC20` surfaces a silent-failure ERC20 (one
    ///         that returns `false` without moving funds) as a
    ///         {SafeERC20.SafeERC20FailedOperation} revert — never a silent
    ///         success.
    function test_recover_returnFalseToken_revertsViaSafeERC20() public {
        (BLOKCContributorAccount account, MaliciousERC20 evil) = _accountWithEvilToken(MaliciousERC20.Mode.ReturnFalse);

        vm.prank(users.contributor);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(evil)));
        account.recoverERC20(address(evil), users.recipient, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Asserts a hard-reverting ERC20 bubbles its revert out of
    ///         `recoverERC20` rather than being swallowed.
    function test_recover_revertingToken_bubblesRevert() public {
        (BLOKCContributorAccount account, MaliciousERC20 evil) = _accountWithEvilToken(MaliciousERC20.Mode.Revert);

        vm.prank(users.contributor);
        vm.expectRevert(bytes("MaliciousERC20: forced revert"));
        account.recoverERC20(address(evil), users.recipient, Constants.DEFAULT_FUND_AMOUNT);
    }

    /// @notice Proves a foreign token cannot drain the account by
    ///         re-entering `recoverERC20` from its `transfer` hook: the
    ///         reentrant call's `msg.sender` is the token, not the
    ///         contributor, so the `onlyContributor` gate reverts the entire
    ///         operation and no funds move.
    function test_recover_reentrantToken_blockedByOnlyContributor() public {
        (BLOKCContributorAccount account, MaliciousERC20 evil) =
            _accountWithEvilToken(MaliciousERC20.Mode.ReenterRecover);
        evil.setReentryTarget(account, users.attacker, Constants.DEFAULT_FUND_AMOUNT);

        uint256 balBefore = evil.balanceOf(address(account));

        vm.prank(users.contributor);
        vm.expectRevert(BLOKCContributorAccount.NotAContributor.selector);
        account.recoverERC20(address(evil), users.recipient, Constants.DEFAULT_FUND_AMOUNT);

        // The whole call reverted: nothing left the account.
        assertEq(evil.balanceOf(address(account)), balBefore, "no foreign token moved");
        assertEq(evil.balanceOf(users.attacker), 0, "attacker received nothing");
        assertEq(evil.balanceOf(users.recipient), 0, "recipient received nothing");
    }
}
