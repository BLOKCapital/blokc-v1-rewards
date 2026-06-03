// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "test/utils/BaseTest.sol";
import {BLOKCAmbassadorAccount} from "src/contracts/BLOKCAmbassadorAccount.sol";
import {Constants} from "test/utils/Constants.sol";

/// @title  LifecycleTest
/// @notice End-to-end integration tests covering the protocol's headline
///         flow — the one the CREATE2 design exists for: pre-fund an
///         ambassador's account at its *predicted* address before it has
///         been deployed, then deploy, delegate, wait out the lock, and
///         withdraw.
///
/// @dev    These tests run the full sequence across multiple actors and
///         the unlock boundary, and assert fund isolation between distinct
///         ambassadors — properties no single unit test exercises.
contract LifecycleTest is BaseTest {
    /// @notice Full happy lifecycle:
    ///         predict → pre-fund the predicted address → third-party deploy
    ///         → account captures the pre-funded balance → re-delegate
    ///         → warp to unlock → withdraw to an external recipient.
    /// @dev    Pre-funding happens BEFORE any contract exists at the
    ///         address, proving the clone inherits the balance sitting at
    ///         its CREATE2 address. Deployment is done by `goodSamaritan`
    ///         to prove the courtesy-deploy path still yields an
    ///         ambassador-owned, funded account.
    function test_prefundThenDeployDelegateWithdraw() public {
        // 1. Predict the address before anything is deployed there.
        address predicted = factory.predictAmbassadorAccount(users.ambassador);
        assertEq(predicted.code.length, 0, "nothing deployed at predicted address yet");

        // 2. Pre-fund the bare address from the "treasury" (deployer).
        _fundAccount(predicted, Constants.DEFAULT_FUND_AMOUNT);
        assertEq(blokc.balanceOf(predicted), Constants.DEFAULT_FUND_AMOUNT, "predicted address holds pre-funded BLOKC");

        // 3. A third party deploys the account on the ambassador's behalf.
        vm.prank(users.goodSamaritan);
        BLOKCAmbassadorAccount account = BLOKCAmbassadorAccount(factory.createAmbassadorAccount(users.ambassador));
        assertEq(address(account), predicted, "deployed exactly at the pre-funded address");

        // 4. The clone now owns the pre-funded balance and is ambassador-owned.
        assertEq(account.balanceOf(), Constants.DEFAULT_FUND_AMOUNT, "clone captured the pre-funded balance");
        assertEq(account.ambassador(), users.ambassador, "owned by named ambassador, not deployer");
        assertEq(blokc.delegates(address(account)), users.ambassador, "voting power delegated to ambassador");
        assertEq(blokc.getVotes(users.ambassador), Constants.DEFAULT_FUND_AMOUNT, "locked tokens count as votes");

        // 5. Ambassador re-routes governance power while still locked.
        vm.prank(users.ambassador);
        account.reDelegate(users.delegatee);
        assertEq(blokc.getVotes(users.delegatee), Constants.DEFAULT_FUND_AMOUNT, "votes moved to delegatee");

        // 6. Locked: withdrawal must fail right up to the boundary.
        _warpToJustBeforeUnlock();
        vm.prank(users.ambassador);
        vm.expectRevert(BLOKCAmbassadorAccount.NoTimelineUnlockedYet.selector);
        account.withdraw(users.recipient, 1);

        // 7. At unlock, the ambassador withdraws the full balance externally.
        _warpToUnlock();
        vm.prank(users.ambassador);
        account.withdraw(users.recipient, Constants.DEFAULT_FUND_AMOUNT);

        assertEq(blokc.balanceOf(users.recipient), Constants.DEFAULT_FUND_AMOUNT, "recipient received everything");
        assertEq(account.balanceOf(), 0, "account drained");
    }

    /// @notice Funds added to the predicted address AFTER deployment are
    ///         also withdrawable — i.e. an account keeps accruing rewards
    ///         over its lifetime, not only at genesis.
    function test_topUpAfterDeploy_isWithdrawableAtUnlock() public {
        BLOKCAmbassadorAccount account = _createAccount(users.ambassador);
        _fundAccount(address(account), 100e18);
        _fundAccount(address(account), 250e18); // a later reward drop
        assertEq(account.balanceOf(), 350e18, "balance accrues across top-ups");

        _warpPastUnlock();
        vm.prank(users.ambassador);
        account.withdrawTokensAll();
        assertEq(blokc.balanceOf(users.ambassador), 350e18, "full accrued amount swept");
    }

    /// @notice Two distinct ambassadors get independent accounts whose
    ///         balances never cross-contaminate, and one withdrawing does
    ///         not affect the other.
    function test_multiAmbassador_fundsAreIsolated() public {
        BLOKCAmbassadorAccount a = _createAccount(users.ambassador);
        BLOKCAmbassadorAccount b = _createAccount(users.otherAmbassador);
        assertTrue(address(a) != address(b), "distinct accounts");

        _fundAccount(address(a), 1_000e18);
        _fundAccount(address(b), 7_000e18);

        _warpPastUnlock();

        // Ambassador A sweeps; B is untouched.
        vm.prank(users.ambassador);
        a.withdrawTokensAll();
        assertEq(blokc.balanceOf(users.ambassador), 1_000e18, "A got exactly its balance");
        assertEq(b.balanceOf(), 7_000e18, "B balance unaffected by A's withdrawal");

        // B's owner cannot touch A, and vice versa.
        vm.prank(users.otherAmbassador);
        vm.expectRevert(BLOKCAmbassadorAccount.NotAnAmbassador.selector);
        a.withdraw(users.otherAmbassador, 1);

        vm.prank(users.otherAmbassador);
        b.withdrawTokensAll();
        assertEq(blokc.balanceOf(users.otherAmbassador), 7_000e18, "B got exactly its balance");
    }
}
