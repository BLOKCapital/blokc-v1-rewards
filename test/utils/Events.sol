// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Re-declared events from the production contracts so tests can
///         use `vm.expectEmit` without importing source. Signatures must
///         match `BLOKCContributorAccount` and `BLOKCContributorFactory`
///         exactly — including `indexed` placement.
abstract contract Events {
    /*//////////////////////////////////////////////////////////////
                         BLOKCContributorAccount
    //////////////////////////////////////////////////////////////*/

    event Initialized(address indexed contributor, address indexed token, uint64 unlockTimestamp);
    event Withdrawn(address indexed to, uint256 amount);
    event AllTokensWithdrawn(address indexed contributor, uint256 balance);
    event NonBLOKCTokensRecovered(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                         BLOKCContributorFactory
    //////////////////////////////////////////////////////////////*/

    event ContributorAccountCreated(address indexed contributor, address indexed account);
}
