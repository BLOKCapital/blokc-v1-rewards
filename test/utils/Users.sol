// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Named test actors. `BaseTest` populates this struct in
///         `setUp()` via `makeAddr` + `vm.label`, so traces show
///         readable names instead of raw 0x addresses.
struct Users {
    /// @notice Deploys the implementation, factory and mock token.
    address payable deployer;
    /// @notice Primary contributor used in single-account flows.
    address payable contributor;
    /// @notice Secondary contributor used in multi-account / idempotency tests.
    address payable otherContributor;
    /// @notice Unauthorized caller used to assert `onlyContributor` reverts.
    address payable attacker;
    /// @notice Withdrawal recipient distinct from the contributor.
    address payable recipient;
    /// @notice Permissionless caller used in factory tests where someone
    ///         other than the contributor deploys the account.
    address payable goodSamaritan;
    /// @notice AI wallet authorized to propose reward distributions.
    address payable aiProposer;
    /// @notice Admin address that manages signers and the proposer.
    address payable distributorOwner;
    /// @notice First designated signer for reward distribution approvals.
    address payable signer1;
    /// @notice Second designated signer for reward distribution approvals.
    address payable signer2;
}
