// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";
import {MockBLOKC} from "test/mocks/MockBLOKC.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {AccountHandler} from "test/invariant/handlers/AccountHandler.sol";
import {Constants} from "test/utils/Constants.sol";

/// @title  AccountInvariant
/// @notice Invariant suite for {BLOKCContributorAccount}, driven by the
///         pre-existing {AccountHandler}. The handler bounds funding,
///         withdrawals, recovery, delegation and time travel so the fuzzer
///         spends its budget on meaningful state rather than reverts.
///
/// @dev    Core properties asserted after every handler call:
///           - Conservation: held $BLOKC == total funded − total withdrawn.
///           - The lock holds: no $BLOKC ever leaves before `unlockTimestamp`.
///           - Configuration is immutable: token / contributor / unlock never
///             change after initialization.
contract AccountInvariant is StdInvariant, Test {
    MockBLOKC internal blokc;
    BLOKCContributorAccount internal implementation;
    BLOKCContributorFactory internal factory;
    BLOKCContributorAccount internal account;
    MockERC20 internal foreignToken;
    AccountHandler internal handler;

    address internal contributor;

    function setUp() public {
        // Start a year before unlock so time-travel only moves forward.
        vm.warp(Constants.START_TIMESTAMP);

        contributor = makeAddr("contributor");

        blokc = new MockBLOKC();
        implementation = new BLOKCContributorAccount();
        factory = new BLOKCContributorFactory(address(blokc), address(implementation), Constants.UNLOCK_TIMESTAMP);
        foreignToken = new MockERC20("Foreign", "FRGN");

        vm.prank(contributor);
        account = BLOKCContributorAccount(factory.createContributorAccount());

        handler = new AccountHandler(account, blokc, foreignToken, contributor);

        // Only the handler is fuzzed, and only its action selectors.
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = AccountHandler.fund.selector;
        selectors[1] = AccountHandler.fundForeign.selector;
        selectors[2] = AccountHandler.withdraw.selector;
        selectors[3] = AccountHandler.withdrawAll.selector;
        selectors[4] = AccountHandler.recoverForeign.selector;
        selectors[5] = AccountHandler.skipTime.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Held $BLOKC always equals total ever funded minus total ever
    ///         withdrawn — no tokens are minted, burned or lost internally.
    function invariant_account_conservation() public view {
        assertEq(
            blokc.balanceOf(address(account)),
            handler.g_totalFunded() - handler.g_totalWithdrawn(),
            "BLOKC conservation broken"
        );
    }

    /// @notice The lock is absolute: not a single $BLOKC leaves the account
    ///         before the unlock timestamp.
    function invariant_account_noWithdrawalBeforeUnlock() public view {
        if (block.timestamp < account.unlockTimestamp()) {
            assertEq(handler.g_totalWithdrawn(), 0, "BLOKC left the account before unlock");
        }
    }

    /// @notice Token, contributor and unlock timestamp are write-once and
    ///         never drift across the account's lifetime.
    function invariant_account_immutableConfig() public view {
        assertEq(account.token(), address(blokc), "token drifted");
        assertEq(account.contributor(), contributor, "contributor drifted");
        assertEq(account.unlockTimestamp(), Constants.UNLOCK_TIMESTAMP, "unlock drifted");
    }
}
