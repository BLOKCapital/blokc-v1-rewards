// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BLOKCContributorFactory} from "../../src/contracts/factory/BLOKCContributorFactory.sol";
import {BLOKCContributorAccount} from "../../src/contracts/BLOKCContributorAccount.sol";
import {Vm} from "forge-std/Vm.sol";
import {Constants} from "test/utils/Constants.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

/// @title  BLOKCContributorFactoryTest
/// @notice Unit tests for {BLOKCContributorFactory}.
/// @dev    Inherits the shared harness in {BaseTest}, which already
///         deploys an inherited `factory` bound to (`blokc`,
///         `implementation`, `UNLOCK_TIMESTAMP`). Most tests use that
///         inherited factory; the constructor tests deploy fresh
///         factories with intentionally-bad arguments.
///
///         Coverage groups:
///           - CONSTRUCTOR              : zero-arg guards and immutables.
///           - CREATE (self overload)   : deploy-at-predicted, init for caller, registry, events.
///           - CREATE (third-party)     : ownership stays with the *named* contributor.
///           - IDEMPOTENCY              : same caller twice, cross-caller, no-emit on return.
///           - MULTI-CONTRIBUTOR         : distinct contributors yield distinct accounts.
contract BLOKCContributorFactoryTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                                   HELPERS
       //////////////////////////////////////////////////////////////*/

    /// @notice Returns the deterministic account address the factory
    ///         will (or has) deployed for `contributor`.
    /// @dev    Thin wrapper around
    ///         {BLOKCContributorFactory.predictContributorAccount} used
    ///         by every test that needs the predicted address.
    /// @param  contributor The contributor to look up.
    /// @return The CREATE2-derived account address.
    function _predicted(address contributor) internal view returns (address) {
        return factory.predictContributorAccount(contributor);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts the constructor reverts with {ZeroAddress} when
    ///         `_token` is `address(0)`.
    function test_constructor_revertWhen_TokenIsZero() public {
        vm.expectRevert(BLOKCContributorFactory.ZeroAddress.selector);
        new BLOKCContributorFactory(address(0), address(implementation), Constants.UNLOCK_TIMESTAMP);
    }

    /// @notice Asserts the constructor reverts with {ZeroAddress} when
    ///         `_implementation` is `address(0)`.
    function test_constructor_revertWhen_ImplementationIsZero() public {
        vm.expectRevert(BLOKCContributorFactory.ZeroAddress.selector);
        new BLOKCContributorFactory(address(blokc), address(0), Constants.UNLOCK_TIMESTAMP);
    }

    /// @notice Asserts the constructor reverts with {ZeroTimestamp} when
    ///         `_unlockTimestamp` is zero — a zero unlock would make every
    ///         clone's {initialize} revert and brick the factory.
    function test_constructor_revertWhen_UnlockTimestampIsZero() public {
        vm.expectRevert(BLOKCContributorFactory.ZeroTimestamp.selector);
        new BLOKCContributorFactory(address(blokc), address(implementation), 0);
    }

    /// @notice Asserts the constructor wires up its three immutables
    ///         and starts with an empty account registry.
    /// @dev    Uses a freshly deployed factory (not the inherited one)
    ///         so the assertions can be checked against known inputs.
    function test_constructor_setsImmutables() public {
        BLOKCContributorFactory factory =
            new BLOKCContributorFactory(address(blokc), address(implementation), Constants.UNLOCK_TIMESTAMP);
        assertEq(factory.token(), address(blokc));
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.unlockTimestamp(), Constants.UNLOCK_TIMESTAMP);
        assertEq(factory.getAccountsLength(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        CREATE — SELF OVERLOAD
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts `createContributorAccount()` (no-arg overload)
    ///         deploys the caller's account at exactly the predicted
    ///         CREATE2 address.
    /// @dev    The predicted address is computed from
    ///         (implementation, salt = contributor, factory). Equality
    ///         between predicted and actual pins the salt rule.
    function test_createContributorAccount_Self_deploysAtPredictedAddress() public {
        address predicted = _predicted(users.contributor);
        vm.prank(users.contributor);
        address actual = factory.createContributorAccount();
        assertEq(actual, predicted, "deployment must match predicted address");
    }

    /// @notice Asserts the no-arg overload initializes the clone with the
    ///         **caller** as contributor, plus the factory's bound token
    ///         and unlock timestamp, and delegates the clone's voting
    ///         power to the caller.
    function test_createContributorAccount_Self_initializesAccountForCaller() public {
        vm.prank(users.contributor);
        BLOKCContributorAccount account = BLOKCContributorAccount(factory.createContributorAccount());
        assertEq(account.contributor(), users.contributor);
        assertEq(account.token(), address(blokc));
        assertEq(account.unlockTimestamp(), Constants.UNLOCK_TIMESTAMP);
        assertEq(blokc.delegates(address(account)), users.contributor);
    }

    /// @notice Asserts all three registry surfaces are populated after
    ///         a successful create.
    /// @dev    Covers both the raw mapping getters
    ///         (`accountOf`, `holdsAccount`) and their verb-named
    ///         aliases (`getAccountOf`, `hasAccount`), plus
    ///         `accounts(0)` and `getAccountsLength()`.
    function test_createContributorAccount_Self_writesRegistry() public {
        vm.prank(users.contributor);
        address account = factory.createContributorAccount();

        assertEq(factory.accountOf(users.contributor), account);
        assertEq(factory.getAccountOf(users.contributor), account);
        assertTrue(factory.holdsAccount(users.contributor));
        assertTrue(factory.hasAccount(users.contributor));
        assertEq(factory.accounts(0), account);
        assertEq(factory.getAccountsLength(), 1);
    }

    /// @notice Asserts the factory emits
    ///         `ContributorAccountCreated(contributor, account)` on a
    ///         fresh deploy.
    /// @dev    Matches both indexed topics (contributor, account) — the
    ///         data field has no non-indexed parameters.
    function test_createContributorAccount_Self_emitsContributorAccountCreated() public {
        address predicted = _predicted(users.contributor);

        vm.expectEmit(true, true, false, false, address(factory));
        emit ContributorAccountCreated(users.contributor, predicted);

        vm.prank(users.contributor);
        factory.createContributorAccount();
    }

    /// @notice Asserts the **clone** emits its own
    ///         `Initialized(contributor, token, unlockTimestamp)` event
    ///         from inside the factory's create call.
    /// @dev    Demonstrates the factory wires up `initialize` correctly,
    ///         not just that it deploys the bytecode.
    function test_createContributorAccount_Self_emitsChildInitialized() public {
        address predicted = _predicted(users.contributor);

        vm.expectEmit(true, true, false, true, predicted);
        emit Initialized(users.contributor, address(blokc), Constants.UNLOCK_TIMESTAMP);

        vm.prank(users.contributor);
        factory.createContributorAccount();
    }

    /*//////////////////////////////////////////////////////////////
                              IDEMPOTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts a second create call from the same contributor
    ///         returns the existing account address without growing the
    ///         `accounts` array.
    function test_createContributorAccount_Idempotent_selfTwiceReturnsSameAddress() public {
        vm.prank(users.contributor);
        address first = factory.createContributorAccount();
        vm.prank(users.contributor);
        address second = factory.createContributorAccount();
        assertEq(first, second);
        assertEq(factory.getAccountsLength(), 1);
    }

    /// @notice Asserts a redundant create emits NO
    ///         `ContributorAccountCreated` event — the idempotent return
    ///         path must be log-silent.
    /// @dev    Records logs across the second call and scans every entry
    ///         for the event signature; none must be present.
    function test_createContributorAccount_Idempotent_secondCallEmitsNothing() public {
        vm.prank(users.contributor);
        factory.createContributorAccount();

        vm.recordLogs();
        vm.prank(users.contributor);
        factory.createContributorAccount();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("ContributorAccountCreated(address,address)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig, "no ContributorAccountCreated on idempotent return");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS / EDGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts the verb-named view aliases return the bound
    ///         immutables: {getToken} and {getUnlockTimestamp}.
    function test_view_getTokenAndUnlock_returnBoundImmutables() public view {
        assertEq(factory.getToken(), address(blokc), "getToken matches token");
        assertEq(factory.getToken(), factory.token(), "alias matches auto-getter");
        assertEq(factory.getUnlockTimestamp(), Constants.UNLOCK_TIMESTAMP, "getUnlockTimestamp matches");
        assertEq(factory.getUnlockTimestamp(), factory.unlockTimestamp(), "alias matches auto-getter");
    }

    /// @notice Asserts {predictContributorAccount} equals the address the
    ///         account is actually deployed at — for both an arbitrary
    ///         pre-deploy contributor and after the real deploy.
    /// @dev    Predicting depends only on the contributor, so the value is
    ///         stable across the deploy transition.
    function test_view_predict_matchesDeployedAddress() public {
        address predictedBefore = factory.predictContributorAccount(users.contributor);

        vm.prank(users.contributor);
        address deployed = factory.createContributorAccount();

        assertEq(deployed, predictedBefore, "deployed matches pre-deploy prediction");
        assertEq(factory.predictContributorAccount(users.contributor), deployed, "prediction stable after deploy");
    }

    /// @notice Asserts an unseen contributor reads as empty across every
    ///         registry surface.
    function test_view_unseenContributor_readsEmpty() public view {
        assertEq(factory.accountOf(users.otherContributor), address(0));
        assertEq(factory.getAccountOf(users.otherContributor), address(0));
        assertFalse(factory.holdsAccount(users.otherContributor));
        assertFalse(factory.hasAccount(users.otherContributor));
    }

    /// @notice Asserts reading `accounts(idx)` past the end of the registry
    ///         reverts (array out-of-bounds).
    /// @dev    No accounts created yet, so index 0 is already out of range.
    function test_view_accounts_outOfBoundsReverts() public {
        vm.expectRevert();
        factory.accounts(0);
    }

    /*//////////////////////////////////////////////////////////////
                              PAGINATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys `n` accounts for distinct synthetic contributors and
    ///         returns their addresses in registry (deploy) order.
    /// @dev    Pranks as each contributor since only self-deploy is allowed.
    function _deployN(uint256 n) internal returns (address[] memory expected) {
        expected = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            address contributor = address(uint160(0x1000 + i));
            vm.prank(contributor);
            expected[i] = factory.createContributorAccount();
        }
    }

    /// @notice {getAccountsLength} tracks the number of distinct contributors.
    function test_pagination_lengthTracksRegistry() public {
        assertEq(factory.getAccountsLength(), 0);
        _deployN(3);
        assertEq(factory.getAccountsLength(), 3);
    }

    /// @notice A page returns exactly the requested window, in registry order.
    function test_pagination_returnsRequestedWindow() public {
        address[] memory expected = _deployN(5);

        address[] memory page = factory.getAccounts(1, 2);
        assertEq(page.length, 2, "page size");
        assertEq(page[0], expected[1], "first of window");
        assertEq(page[1], expected[2], "second of window");
    }

    /// @notice A `limit` beyond the remaining entries (incl. the max value)
    ///         is clamped to the array length and never reverts.
    function test_pagination_limitClampedAndNeverReverts() public {
        address[] memory expected = _deployN(3);

        address[] memory page = factory.getAccounts(1, type(uint256).max);
        assertEq(page.length, 2, "clamped to remaining");
        assertEq(page[0], expected[1]);
        assertEq(page[1], expected[2]);
    }

    /// @notice An `offset` at or past the end yields an empty page, never reverts.
    function test_pagination_offsetPastEndReturnsEmpty() public {
        _deployN(2);
        assertEq(factory.getAccounts(2, 10).length, 0, "offset == length");
        assertEq(factory.getAccounts(99, 10).length, 0, "offset past length");
    }

    /// @notice An empty registry returns an empty page for any window.
    function test_pagination_emptyRegistry() public view {
        assertEq(factory.getAccountsLength(), 0);
        assertEq(factory.getAccounts(0, 10).length, 0);
    }

    /// @notice Walking the registry in fixed-size pages reconstructs the
    ///         full list, in order, covering every entry exactly once.
    function test_pagination_walkReconstructsFullList() public {
        address[] memory expected = _deployN(5);

        uint256 len = factory.getAccountsLength();
        uint256 pageSize = 2;
        address[] memory all = new address[](len);
        uint256 k;
        for (uint256 offset = 0; offset < len; offset += pageSize) {
            address[] memory page = factory.getAccounts(offset, pageSize);
            for (uint256 i = 0; i < page.length; ++i) {
                all[k++] = page[i];
            }
        }

        assertEq(k, len, "covered every entry exactly once");
        for (uint256 i = 0; i < len; ++i) {
            assertEq(all[i], expected[i], "order preserved across pages");
        }
    }

    /*//////////////////////////////////////////////////////////////
                          MULTI-CONTRIBUTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts two distinct contributors get two distinct,
    ///         independently-owned accounts.
    /// @dev    Validates (a) the deployed addresses differ, (b) the
    ///         `accounts` array indexes them in deploy order, and
    ///         (c) each account is initialized for the right
    ///         contributor.
    function test_createContributorAccount_DistinctContributors_getDistinctAccounts() public {
        vm.prank(users.contributor);
        address accountX = factory.createContributorAccount();
        vm.prank(users.otherContributor);
        address accountY = factory.createContributorAccount();

        assertTrue(accountX != accountY, "distinct contributors to distinct accounts");
        assertEq(factory.getAccountsLength(), 2);
        assertEq(factory.accounts(0), accountX);
        assertEq(factory.accounts(1), accountY);
        assertEq(BLOKCContributorAccount(accountX).contributor(), users.contributor);
        assertEq(BLOKCContributorAccount(accountY).contributor(), users.otherContributor);
    }
}
