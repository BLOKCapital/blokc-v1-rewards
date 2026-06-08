// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "test/utils/BaseTest.sol";
import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {MaliciousERC20} from "test/mocks/MaliciousERC20.sol";
import {Constants} from "test/utils/Constants.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  ReentrancyTest
/// @notice Integration tests exercising {BLOKCContributorAccount}'s
///         `recoverERC20` against adversarial ERC20 tokens — return-false,
///         hard-revert, and reentrant tokens. The `onlyContributor` gate
///         blocks all token-callback reentrancy since `msg.sender` is the
///         token during callbacks, never the contributor.
contract ReentrancyTest is BaseTest {
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
