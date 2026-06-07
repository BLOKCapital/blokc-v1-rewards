// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "test/utils/BaseTest.sol";
import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";
import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {Constants} from "test/utils/Constants.sol";

/// @title  FactoryFuzzTest
/// @notice Property/fuzz tests for {BLOKCContributorFactory}. Where the unit
///         tests pin behaviour for the named users, these sweep the
///         contributor address space: deployment must always land at the
///         predicted CREATE2 address, bind ownership to the named
///         contributor, and stay idempotent across repeated and cross-caller
///         creates.
contract FactoryFuzzTest is BaseTest {
    /// @notice Restricts a fuzzed contributor to a non-zero address (zero is
    ///         rejected by the factory and covered by a unit test).
    function _assumeValidContributor(address contributor) internal pure {
        vm.assume(contributor != address(0));
    }

    /// @notice For any non-zero contributor, the third-party create deploys
    ///         at exactly the predicted address and initializes the clone
    ///         for the named contributor with the factory's bound token and
    ///         unlock timestamp.
    function testFuzz_create_deploysAtPredictedAndBindsOwner(address contributor) public {
        _assumeValidContributor(contributor);

        address predicted = factory.predictContributorAccount(contributor);

        vm.prank(users.goodSamaritan);
        BLOKCContributorAccount account = BLOKCContributorAccount(factory.createContributorAccount(contributor));

        assertEq(address(account), predicted, "deployed at predicted address");
        assertEq(account.contributor(), contributor, "ownership bound to named contributor");
        assertEq(account.token(), address(blokc), "token bound");
        assertEq(account.unlockTimestamp(), Constants.UNLOCK_TIMESTAMP, "unlock bound");
        assertEq(blokc.delegates(address(account)), contributor, "votes delegated to contributor");
    }

    /// @notice For any non-zero contributor, the predicted address depends on
    ///         the contributor alone and is stable across the deploy
    ///         transition.
    function testFuzz_predict_stableAcrossDeploy(address contributor) public {
        _assumeValidContributor(contributor);

        address predictedBefore = factory.predictContributorAccount(contributor);

        vm.prank(users.goodSamaritan);
        address deployed = factory.createContributorAccount(contributor);

        assertEq(deployed, predictedBefore, "deployed matches pre-deploy prediction");
        assertEq(factory.predictContributorAccount(contributor), deployed, "prediction stable after deploy");
    }

    /// @notice For any non-zero contributor, creating twice (and across
    ///         different callers) is idempotent: the same address is
    ///         returned and the registry grows by exactly one.
    function testFuzz_create_idempotent(address contributor) public {
        _assumeValidContributor(contributor);

        vm.prank(contributor);
        address first = factory.createContributorAccount();

        vm.prank(users.goodSamaritan);
        address second = factory.createContributorAccount(contributor);

        assertEq(first, second, "same account across repeated/cross-caller create");
        assertEq(factory.accountOf(contributor), first, "registry records the account");
        assertTrue(factory.holdsAccount(contributor), "holdsAccount set");
        assertEq(factory.getAccountsLength(), 1, "registry grew by exactly one");
    }

    /// @notice Two distinct non-zero contributors always get two distinct,
    ///         independently-owned accounts.
    function testFuzz_distinctContributors_getDistinctAccounts(address a, address b) public {
        _assumeValidContributor(a);
        _assumeValidContributor(b);
        vm.assume(a != b);

        vm.prank(a);
        address accountA = factory.createContributorAccount();
        vm.prank(b);
        address accountB = factory.createContributorAccount();

        assertTrue(accountA != accountB, "distinct contributors yield distinct accounts");
        assertEq(BLOKCContributorAccount(accountA).contributor(), a, "account A owned by a");
        assertEq(BLOKCContributorAccount(accountB).contributor(), b, "account B owned by b");
        assertEq(factory.getAccountsLength(), 2, "registry holds both");
    }
}
