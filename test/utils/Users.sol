// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Named test actors. `BaseTest` populates this struct in
///         `setUp()` via `makeAddr` + `vm.label`, so traces show
///         readable names instead of raw 0x addresses.
struct Users {
    /// @notice Deploys the implementation, factory and mock token.
    address payable deployer;
    /// @notice Primary ambassador used in single-account flows.
    address payable ambassador;
    /// @notice Secondary ambassador used in multi-account / idempotency tests.
    address payable otherAmbassador;
    /// @notice Unauthorized caller used to assert `onlyAmbassador` reverts.
    address payable attacker;
    /// @notice Withdrawal recipient distinct from the ambassador.
    address payable recipient;
    /// @notice Delegatee target used in `reDelegate` tests.
    address payable delegatee;
    /// @notice Permissionless caller used in factory tests where someone
    ///         other than the ambassador deploys the account.
    address payable goodSamaritan;
}
