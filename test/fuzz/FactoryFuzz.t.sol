// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "test/utils/BaseTest.sol";
import {BLOKCAmbassadorFactory} from "src/contracts/factory/BLOKCAmbassadorFactory.sol";
import {BLOKCAmbassadorAccount} from "src/contracts/BLOKCAmbassadorAccount.sol";
import {Constants} from "test/utils/Constants.sol";

/// @title  FactoryFuzzTest
/// @notice Property/fuzz tests for {BLOKCAmbassadorFactory}. Where the unit
///         tests pin behaviour for the named users, these sweep the
///         ambassador address space: deployment must always land at the
///         predicted CREATE2 address, bind ownership to the named
///         ambassador, and stay idempotent across repeated and cross-caller
///         creates.
contract FactoryFuzzTest is BaseTest {
    /// @notice Restricts a fuzzed ambassador to a non-zero address (zero is
    ///         rejected by the factory and covered by a unit test).
    function _assumeValidAmbassador(address ambassador) internal pure {
        vm.assume(ambassador != address(0));
    }

    /// @notice For any non-zero ambassador, the third-party create deploys
    ///         at exactly the predicted address and initializes the clone
    ///         for the named ambassador with the factory's bound token and
    ///         unlock timestamp.
    function testFuzz_create_deploysAtPredictedAndBindsOwner(address ambassador) public {
        _assumeValidAmbassador(ambassador);

        address predicted = factory.predictAmbassadorAccount(ambassador);

        vm.prank(users.goodSamaritan);
        BLOKCAmbassadorAccount account = BLOKCAmbassadorAccount(factory.createAmbassadorAccount(ambassador));

        assertEq(address(account), predicted, "deployed at predicted address");
        assertEq(account.ambassador(), ambassador, "ownership bound to named ambassador");
        assertEq(account.token(), address(blokc), "token bound");
        assertEq(account.unlockTimestamp(), Constants.UNLOCK_TIMESTAMP, "unlock bound");
        assertEq(blokc.delegates(address(account)), ambassador, "votes delegated to ambassador");
    }

    /// @notice For any non-zero ambassador, the predicted address depends on
    ///         the ambassador alone and is stable across the deploy
    ///         transition.
    function testFuzz_predict_stableAcrossDeploy(address ambassador) public {
        _assumeValidAmbassador(ambassador);

        address predictedBefore = factory.predictAmbassadorAccount(ambassador);

        vm.prank(users.goodSamaritan);
        address deployed = factory.createAmbassadorAccount(ambassador);

        assertEq(deployed, predictedBefore, "deployed matches pre-deploy prediction");
        assertEq(factory.predictAmbassadorAccount(ambassador), deployed, "prediction stable after deploy");
    }

    /// @notice For any non-zero ambassador, creating twice (and across
    ///         different callers) is idempotent: the same address is
    ///         returned and the registry grows by exactly one.
    function testFuzz_create_idempotent(address ambassador) public {
        _assumeValidAmbassador(ambassador);

        vm.prank(ambassador);
        address first = factory.createAmbassadorAccount();

        vm.prank(users.goodSamaritan);
        address second = factory.createAmbassadorAccount(ambassador);

        assertEq(first, second, "same account across repeated/cross-caller create");
        assertEq(factory.accountOf(ambassador), first, "registry records the account");
        assertTrue(factory.holdsAccount(ambassador), "holdsAccount set");
        assertEq(factory.getAllAccounts().length, 1, "registry grew by exactly one");
    }

    /// @notice Two distinct non-zero ambassadors always get two distinct,
    ///         independently-owned accounts.
    function testFuzz_distinctAmbassadors_getDistinctAccounts(address a, address b) public {
        _assumeValidAmbassador(a);
        _assumeValidAmbassador(b);
        vm.assume(a != b);

        vm.prank(a);
        address accountA = factory.createAmbassadorAccount();
        vm.prank(b);
        address accountB = factory.createAmbassadorAccount();

        assertTrue(accountA != accountB, "distinct ambassadors yield distinct accounts");
        assertEq(BLOKCAmbassadorAccount(accountA).ambassador(), a, "account A owned by a");
        assertEq(BLOKCAmbassadorAccount(accountB).ambassador(), b, "account B owned by b");
        assertEq(factory.getAllAccounts().length, 2, "registry holds both");
    }
}
