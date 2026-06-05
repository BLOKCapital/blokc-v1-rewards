// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";
import {MockBLOKC} from "test/mocks/MockBLOKC.sol";
import {FactoryHandler} from "test/invariant/handlers/FactoryHandler.sol";
import {Constants} from "test/utils/Constants.sol";

/// @title  FactoryInvariant
/// @notice Invariant suite for {BLOKCContributorFactory}, driven by the
///         pre-existing {FactoryHandler}. The handler creates accounts for
///         a fixed contributor pool via both overloads and re-creates for
///         existing contributors to hammer the idempotent short-circuit.
///
/// @dev    Properties asserted after every handler call:
///           - Registry length equals the number of distinct contributors.
///           - Every contributor maps to a stable, non-zero account that
///             equals both the handler's last-returned address and the
///             factory's own deterministic prediction.
///           - Every registered account is owned by a contributor that maps
///             back to it (no orphans, no aliasing).
contract FactoryInvariant is StdInvariant, Test {
    MockBLOKC internal blokc;
    BLOKCContributorAccount internal implementation;
    BLOKCContributorFactory internal factory;
    FactoryHandler internal handler;

    function setUp() public {
        vm.warp(Constants.START_TIMESTAMP);

        blokc = new MockBLOKC();
        implementation = new BLOKCContributorAccount();
        factory = new BLOKCContributorFactory(address(blokc), address(implementation), Constants.UNLOCK_TIMESTAMP);

        address[] memory pool = new address[](4);
        pool[0] = makeAddr("amb0");
        pool[1] = makeAddr("amb1");
        pool[2] = makeAddr("amb2");
        pool[3] = makeAddr("amb3");

        handler = new FactoryHandler(factory, pool);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = FactoryHandler.createForPoolMember.selector;
        selectors[1] = FactoryHandler.createAgainForExisting.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The append-only registry holds exactly one entry per distinct
    ///         contributor — idempotent re-creates never grow it.
    function invariant_factory_registryLengthMatchesUnique() public view {
        assertEq(factory.getAccountsLength(), handler.g_uniqueContributors(), "registry length != unique contributors");
    }

    /// @notice Each seen contributor maps to a stable, non-zero account that
    ///         matches both the handler's record and the factory's
    ///         deterministic prediction.
    function invariant_factory_accountStableAndPredicted() public view {
        uint256 n = handler.seenContributorsLength();
        for (uint256 i; i < n; ++i) {
            address amb = handler.g_seenContributors(i);
            address acct = factory.accountOf(amb);
            assertTrue(acct != address(0), "seen contributor has no account");
            assertEq(acct, handler.g_lastReturned(amb), "account address drifted from handler record");
            assertEq(acct, factory.predictContributorAccount(amb), "account != deterministic prediction");
            assertTrue(factory.holdsAccount(amb), "holdsAccount false for seen contributor");
        }
    }

    /// @notice Every account in the registry is owned by a contributor that
    ///         maps back to that same account — no orphaned or aliased
    ///         entries.
    function invariant_factory_everyAccountOwnedAndBacklinked() public view {
        address[] memory accounts = factory.getAccounts(0, factory.getAccountsLength());
        for (uint256 i; i < accounts.length; ++i) {
            address owner = BLOKCContributorAccount(accounts[i]).contributor();
            assertEq(factory.accountOf(owner), accounts[i], "account not backlinked to its owner");
        }
    }
}
