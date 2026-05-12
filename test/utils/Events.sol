// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Re-declared events from the production contracts so tests can
///         use `vm.expectEmit` without importing source. Signatures must
///         match `BLOKCAmbassadorAccount` and `BLOKCAmbassadorFactory`
///         exactly — including `indexed` placement.
abstract contract Events {
    /*//////////////////////////////////////////////////////////////
                         BLOKCAmbassadorAccount
    //////////////////////////////////////////////////////////////*/

    event Initialized(address indexed ambassador, address indexed token, uint64 unlockTimestamp);
    event Redelegated(address indexed to);
    event Withdrawn(address indexed to, uint256 amount);
    event AllTokensWithdrawn(address indexed ambassador, uint256 balance);
    event NonBLOKCTokensRecovered(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                         BLOKCAmbassadorFactory
    //////////////////////////////////////////////////////////////*/

    event AmbassadorAccountCreated(address indexed ambassador, address indexed account);
}
