// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {BLOKCDistributor} from "src/contracts/BLOKCDistributor.sol";
import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";
import {MaliciousBLOKC} from "test/mocks/MaliciousBLOKC.sol";

/// @title  DistributorReentrancyTest
/// @notice Verifies that {BLOKCDistributor.executeDistribution} is
///         protected against reentrancy via a malicious $BLOKC token
///         that calls back into the distributor during a transfer.
contract DistributorReentrancyTest is Test {
    MaliciousBLOKC internal token;
    BLOKCContributorAccount internal implementation;
    BLOKCContributorFactory internal factory;
    BLOKCDistributor internal distributor;

    address internal proposer;
    address internal owner;
    address internal signer1;
    address internal signer2;

    uint256 internal constant UNLOCK_TIMESTAMP = 1_809_734_400;
    uint256 internal constant FUND_AMOUNT = 10_000e18;

    function setUp() public {
        proposer = makeAddr("proposer");
        owner = makeAddr("owner");
        signer1 = makeAddr("signer1");
        signer2 = makeAddr("signer2");

        token = new MaliciousBLOKC();

        implementation = new BLOKCContributorAccount();

        factory = new BLOKCContributorFactory(address(token), address(implementation), uint64(UNLOCK_TIMESTAMP));

        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;
        distributor = new BLOKCDistributor(address(token), factory, proposer, owner, signers, 2);

        // Fund the distributor with the malicious token
        token.mint(address(distributor), FUND_AMOUNT);
    }

    /// @notice Asserts that a malicious token re-entering
    ///         {executeDistribution} during a transfer is blocked by the
    ///         CEI pattern — `executed` is set to true before the first
    ///         transfer, so the reentrant call hits {AlreadyExecuted}.
    function test_execute_reentrancy_blockedByCEI() public {
        // Set up a single-contributor distribution
        address[] memory contributors = new address[](1);
        contributors[0] = makeAddr("contributor");
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        // Propose and approve
        vm.prank(proposer);
        distributor.proposeDistribution(1, contributors, amounts);

        vm.prank(signer1);
        distributor.approveDistribution(1);

        vm.prank(signer2);
        distributor.approveDistribution(1);

        // Arm the malicious token to re-enter during transfer
        token.setReentryTarget(distributor, 1);
        token.setReenter(true);

        // The first transfer triggers the reentrant callback, which
        // tries executeDistribution(1) again. That inner call hits
        // AlreadyExecuted (CEI: `dist.executed = true` was set before
        // the loop). The revert bubbles up through transfer →
        // safeTransfer, reverting the outer transaction. State is safe.
        vm.expectRevert(BLOKCDistributor.AlreadyExecuted.selector);
        distributor.executeDistribution(1);
    }
}
