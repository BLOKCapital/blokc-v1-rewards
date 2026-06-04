// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BLOKCAmbassadorFactory} from "../../src/contracts/factory/BLOKCAmbassadorFactory.sol";
import {BLOKCAmbassadorAccount} from "../../src/contracts/BLOKCAmbassadorAccount.sol";
import {Vm} from "forge-std/Vm.sol";
import {Constants} from "test/utils/Constants.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

/// @title  BLOKCAmbassadorFactoryTest
/// @notice Unit tests for {BLOKCAmbassadorFactory}.
/// @dev    Inherits the shared harness in {BaseTest}, which already
///         deploys an inherited `factory` bound to (`blokc`,
///         `implementation`, `UNLOCK_TIMESTAMP`). Most tests use that
///         inherited factory; the constructor tests deploy fresh
///         factories with intentionally-bad arguments.
///
///         Coverage groups:
///           - CONSTRUCTOR              : zero-arg guards and immutables.
///           - CREATE (self overload)   : deploy-at-predicted, init for caller, registry, events.
///           - CREATE (third-party)     : ownership stays with the *named* ambassador.
///           - IDEMPOTENCY              : same caller twice, cross-caller, no-emit on return.
///           - MULTI-AMBASSADOR         : distinct ambassadors yield distinct accounts.
contract BLOKCAmbassadorFactoryTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                                   HELPERS
       //////////////////////////////////////////////////////////////*/

    /// @notice Returns the deterministic account address the factory
    ///         will (or has) deployed for `ambassador`.
    /// @dev    Thin wrapper around
    ///         {BLOKCAmbassadorFactory.predictAmbassadorAccount} used
    ///         by every test that needs the predicted address.
    /// @param  ambassador The ambassador to look up.
    /// @return The CREATE2-derived account address.
    function _predicted(address ambassador) internal view returns (address) {
        return factory.predictAmbassadorAccount(ambassador);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts the constructor reverts with {ZeroAddress} when
    ///         `_token` is `address(0)`.
    function test_constructor_revertWhen_TokenIsZero() public {
        vm.expectRevert(BLOKCAmbassadorFactory.ZeroAddress.selector);
        new BLOKCAmbassadorFactory(address(0), address(implementation), Constants.UNLOCK_TIMESTAMP);
    }

    /// @notice Asserts the constructor reverts with {ZeroAddress} when
    ///         `_implementation` is `address(0)`.
    function test_constructor_revertWhen_ImplementationIsZero() public {
        vm.expectRevert(BLOKCAmbassadorFactory.ZeroAddress.selector);
        new BLOKCAmbassadorFactory(address(blokc), address(0), Constants.UNLOCK_TIMESTAMP);
    }

    /// @notice Asserts the constructor reverts with {ZeroTimestamp} when
    ///         `_unlockTimestamp` is zero — a zero unlock would make every
    ///         clone's {initialize} revert and brick the factory.
    function test_constructor_revertWhen_UnlockTimestampIsZero() public {
        vm.expectRevert(BLOKCAmbassadorFactory.ZeroTimestamp.selector);
        new BLOKCAmbassadorFactory(address(blokc), address(implementation), 0);
    }

    /// @notice Asserts the constructor wires up its three immutables
    ///         and starts with an empty account registry.
    /// @dev    Uses a freshly deployed factory (not the inherited one)
    ///         so the assertions can be checked against known inputs.
    function test_constructor_setsImmutables() public {
        BLOKCAmbassadorFactory factory =
            new BLOKCAmbassadorFactory(address(blokc), address(implementation), Constants.UNLOCK_TIMESTAMP);
        assertEq(factory.token(), address(blokc));
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.unlockTimestamp(), Constants.UNLOCK_TIMESTAMP);
        assertEq(factory.getAllAccounts().length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        CREATE — SELF OVERLOAD
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts `createAmbassadorAccount()` (no-arg overload)
    ///         deploys the caller's account at exactly the predicted
    ///         CREATE2 address.
    /// @dev    The predicted address is computed from
    ///         (implementation, salt = ambassador, factory). Equality
    ///         between predicted and actual pins the salt rule.
    function test_createAmbassadorAccount_Self_deploysAtPredictedAddress() public {
        address predicted = _predicted(users.ambassador);
        vm.prank(users.ambassador);
        address actual = factory.createAmbassadorAccount();
        assertEq(actual, predicted, "deployment must match predicted address");
    }

    /// @notice Asserts the no-arg overload initializes the clone with the
    ///         **caller** as ambassador, plus the factory's bound token
    ///         and unlock timestamp, and delegates the clone's voting
    ///         power to the caller.
    function test_createAmbassadorAccount_Self_initializesAccountForCaller() public {
        vm.prank(users.ambassador);
        BLOKCAmbassadorAccount account = BLOKCAmbassadorAccount(factory.createAmbassadorAccount());
        assertEq(account.ambassador(), users.ambassador);
        assertEq(account.token(), address(blokc));
        assertEq(account.unlockTimestamp(), Constants.UNLOCK_TIMESTAMP);
        assertEq(blokc.delegates(address(account)), users.ambassador);
    }

    /// @notice Asserts all three registry surfaces are populated after
    ///         a successful create.
    /// @dev    Covers both the raw mapping getters
    ///         (`accountOf`, `holdsAccount`) and their verb-named
    ///         aliases (`getAccountOf`, `hasAccount`), plus
    ///         `accounts(0)` and `getAllAccounts().length`.
    function test_createAmbassadorAccount_Self_writesRegistry() public {
        vm.prank(users.ambassador);
        address account = factory.createAmbassadorAccount();

        assertEq(factory.accountOf(users.ambassador), account);
        assertEq(factory.getAccountOf(users.ambassador), account);
        assertTrue(factory.holdsAccount(users.ambassador));
        assertTrue(factory.hasAccount(users.ambassador));
        assertEq(factory.accounts(0), account);
        assertEq(factory.getAllAccounts().length, 1);
    }

    /// @notice Asserts the factory emits
    ///         `AmbassadorAccountCreated(ambassador, account)` on a
    ///         fresh deploy.
    /// @dev    Matches both indexed topics (ambassador, account) — the
    ///         data field has no non-indexed parameters.
    function test_createAmbassadorAccount_Self_emitsAmbassadorAccountCreated() public {
        address predicted = _predicted(users.ambassador);

        vm.expectEmit(true, true, false, false, address(factory));
        emit AmbassadorAccountCreated(users.ambassador, predicted);

        vm.prank(users.ambassador);
        factory.createAmbassadorAccount();
    }

    /// @notice Asserts the **clone** emits its own
    ///         `Initialized(ambassador, token, unlockTimestamp)` event
    ///         from inside the factory's create call.
    /// @dev    Demonstrates the factory wires up `initialize` correctly,
    ///         not just that it deploys the bytecode.
    function test_createAmbassadorAccount_Self_emitsChildInitialized() public {
        address predicted = _predicted(users.ambassador);

        vm.expectEmit(true, true, false, true, predicted);
        emit Initialized(users.ambassador, address(blokc), Constants.UNLOCK_TIMESTAMP);

        vm.prank(users.ambassador);
        factory.createAmbassadorAccount();
    }

    /*//////////////////////////////////////////////////////////////
                       CREATE — THIRD-PARTY OVERLOAD
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts `createAmbassadorAccount(address)` (the
    ///         third-party overload) reverts with {ZeroAddress} when
    ///         the ambassador argument is zero.
    function test_createAmbassadorAccount_Other_revertWhen_AmbassadorIsZero() public {
        vm.prank(users.goodSamaritan);
        vm.expectRevert(BLOKCAmbassadorFactory.ZeroAddress.selector);
        factory.createAmbassadorAccount(address(0));
    }

    /// @notice Asserts that when someone *other* than the ambassador
    ///         deploys their account, ownership still belongs to the
    ///         **named** ambassador, never to the caller.
    /// @dev    This is the headline property of the third-party
    ///         overload (BIP-002 §11.3). Verifies via both `ambassador()`
    ///         and `delegates(account)`.
    function test_createAmbassadorAccount_Other_assignsOwnershipToNamedAmbassador() public {
        vm.prank(users.goodSamaritan);
        BLOKCAmbassadorAccount a = BLOKCAmbassadorAccount(factory.createAmbassadorAccount(users.ambassador));
        assertEq(a.ambassador(), users.ambassador, "ambassador is the named one");
        assertTrue(a.ambassador() != users.goodSamaritan, "caller is not owner");
        assertEq(blokc.delegates(address(a)), users.ambassador, "delegate is the ambassador");
    }

    /// @notice Asserts the third-party overload deploys at the same
    ///         predicted CREATE2 address as the self overload.
    /// @dev    Pins the invariant that the predicted address depends
    ///         on the ambassador alone — never on the caller.
    function test_createAmbassadorAccount_Other_deploysAtSamePredictedAddress() public {
        address predicted = _predicted(users.ambassador);
        vm.prank(users.goodSamaritan);
        address actual = factory.createAmbassadorAccount(users.ambassador);
        assertEq(actual, predicted);
    }

    /// @notice Asserts the third-party overload also emits
    ///         `AmbassadorAccountCreated(ambassador, account)`, with the
    ///         **ambassador** as the indexed actor (not the caller).
    function test_createAmbassadorAccount_Other_emitsEvent() public {
        address predicted = _predicted(users.ambassador);

        vm.expectEmit(true, true, false, false, address(factory));
        emit AmbassadorAccountCreated(users.ambassador, predicted);

        vm.prank(users.goodSamaritan);
        factory.createAmbassadorAccount(users.ambassador);
    }

    /*//////////////////////////////////////////////////////////////
                              IDEMPOTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts a second self-create call from the same address
    ///         returns the existing account address without growing the
    ///         `accounts` array.
    function test_createAmbassadorAccount_Idempotent_selfTwiceReturnsSameAddress() public {
        vm.prank(users.ambassador);
        address first = factory.createAmbassadorAccount();
        vm.prank(users.ambassador);
        address second = factory.createAmbassadorAccount();
        assertEq(first, second);
        assertEq(factory.getAllAccounts().length, 1);
    }

    /// @notice Asserts idempotency holds across **different callers**:
    ///         self-create followed by a third-party "re-create" for
    ///         the same ambassador returns the same address and does
    ///         not grow the registry.
    function test_createAmbassadorAccount_Idempotent_acrossDifferentCallers() public {
        vm.prank(users.ambassador);
        address first = factory.createAmbassadorAccount();

        // Different caller,same ambassador tosame account.
        vm.prank(users.goodSamaritan);
        address second = factory.createAmbassadorAccount(users.ambassador);

        assertEq(first, second);
        assertEq(factory.getAllAccounts().length, 1);
    }

    /// @notice Asserts a redundant create emits NO
    ///         `AmbassadorAccountCreated` event — the idempotent return
    ///         path must be log-silent.
    /// @dev    Records logs across the second call and scans every entry
    ///         for the event signature; none must be present.
    function test_createAmbassadorAccount_Idempotent_secondCallEmitsNothing() public {
        vm.prank(users.ambassador);
        factory.createAmbassadorAccount();

        vm.recordLogs();
        vm.prank(users.ambassador);
        factory.createAmbassadorAccount();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("AmbassadorAccountCreated(address,address)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig, "no AmbassadorAccountCreated on idempotent return");
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

    /// @notice Asserts {predictAmbassadorAccount} equals the address the
    ///         account is actually deployed at — for both an arbitrary
    ///         pre-deploy ambassador and after the real deploy.
    /// @dev    Predicting depends only on the ambassador, so the value is
    ///         stable across the deploy transition.
    function test_view_predict_matchesDeployedAddress() public {
        address predictedBefore = factory.predictAmbassadorAccount(users.ambassador);

        vm.prank(users.ambassador);
        address deployed = factory.createAmbassadorAccount();

        assertEq(deployed, predictedBefore, "deployed matches pre-deploy prediction");
        assertEq(factory.predictAmbassadorAccount(users.ambassador), deployed, "prediction stable after deploy");
    }

    /// @notice Asserts an unseen ambassador reads as empty across every
    ///         registry surface.
    function test_view_unseenAmbassador_readsEmpty() public view {
        assertEq(factory.accountOf(users.otherAmbassador), address(0));
        assertEq(factory.getAccountOf(users.otherAmbassador), address(0));
        assertFalse(factory.holdsAccount(users.otherAmbassador));
        assertFalse(factory.hasAccount(users.otherAmbassador));
    }

    /// @notice Asserts reading `accounts(idx)` past the end of the registry
    ///         reverts (array out-of-bounds).
    /// @dev    No accounts created yet, so index 0 is already out of range.
    function test_view_accounts_outOfBoundsReverts() public {
        vm.expectRevert();
        factory.accounts(0);
    }

    /*//////////////////////////////////////////////////////////////
                          MULTI-AMBASSADOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts two distinct ambassadors get two distinct,
    ///         independently-owned accounts.
    /// @dev    Validates (a) the deployed addresses differ, (b) the
    ///         `accounts` array indexes them in deploy order, and
    ///         (c) each account is initialized for the right
    ///         ambassador.
    function test_createAmbassadorAccount_DistinctAmbassadors_getDistinctAccounts() public {
        vm.prank(users.ambassador);
        address accountX = factory.createAmbassadorAccount();
        vm.prank(users.otherAmbassador);
        address accountY = factory.createAmbassadorAccount();

        assertTrue(accountX != accountY, "distinct ambassadors to distinct accounts");
        assertEq(factory.getAllAccounts().length, 2);
        assertEq(factory.accounts(0), accountX);
        assertEq(factory.accounts(1), accountY);
        assertEq(BLOKCAmbassadorAccount(accountX).ambassador(), users.ambassador);
        assertEq(BLOKCAmbassadorAccount(accountY).ambassador(), users.otherAmbassador);
    }
}
