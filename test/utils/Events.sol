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

    /*//////////////////////////////////////////////////////////////
                         RewardDistributor
    //////////////////////////////////////////////////////////////*/

    event DistributionProposed(
        uint256 indexed epochId, uint256 indexed totalAmount, address[] contributors, uint256[] amounts
    );
    event DistributionApproved(uint256 indexed epochId, address indexed signer, uint256 approvalCount);
    event DistributionExecuted(uint256 indexed epochId, uint256 totalAmount, uint256 contributorCount);
    event DistributionCancelled(uint256 indexed epochId);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ProposerUpdated(address indexed oldProposer, address indexed newProposer);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event TokensRecovered(address indexed recoveredToken, address indexed to, uint256 amount);
}
