// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {RewardDistributor} from "src/contracts/RewardDistributor.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

/// @title  DistributorLifecycleTest
/// @notice Integration tests for the full RewardDistributor lifecycle:
///         propose → approve → execute across multiple epochs.
contract DistributorLifecycleTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _fundDistributor();
    }

    /// @notice Full lifecycle: AI proposes, 2 signers approve, execute,
    ///         verify token balances for 3 contributors across 2 epochs.
    function test_fullLifecycle_twoEpochs() public {
        address[] memory c = _createContributors(3);
        uint256[] memory a1 = new uint256[](3);
        a1[0] = 300e18;
        a1[1] = 200e18;
        a1[2] = 100e18;

        // Epoch 1
        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, a1);

        vm.prank(users.signer1);
        distributor.approveDistribution(1);
        vm.prank(users.signer2);
        distributor.approveDistribution(1);

        distributor.executeDistribution(1);

        address acc0 = factory.predictContributorAccount(c[0]);
        address acc1 = factory.predictContributorAccount(c[1]);
        address acc2 = factory.predictContributorAccount(c[2]);

        assertEq(blokc.balanceOf(acc0), 300e18);
        assertEq(blokc.balanceOf(acc1), 200e18);
        assertEq(blokc.balanceOf(acc2), 100e18);

        // Epoch 2 — different amounts
        uint256[] memory a2 = new uint256[](3);
        a2[0] = 150e18;
        a2[1] = 250e18;
        a2[2] = 200e18;

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(2, c, a2);

        vm.prank(users.signer1);
        distributor.approveDistribution(2);
        vm.prank(users.signer2);
        distributor.approveDistribution(2);

        distributor.executeDistribution(2);

        // Accumulated balances
        assertEq(blokc.balanceOf(acc0), 300e18 + 150e18);
        assertEq(blokc.balanceOf(acc1), 200e18 + 250e18);
        assertEq(blokc.balanceOf(acc2), 100e18 + 200e18);

        // Both epochs marked executed
        assertTrue(distributor.isEpochExecuted(1));
        assertTrue(distributor.isEpochExecuted(2));
    }

    /// @notice After owner rotates the AI wallet, old proposer is
    ///         rejected but new proposer can propose and execute.
    function test_proposerRotation_oldRejectedNewWorks() public {
        address newProposer = address(0xBEEF);
        vm.prank(users.distributorOwner);
        distributor.updateProposer(newProposer);

        address[] memory c = _createContributors(1);
        uint256[] memory a = new uint256[](1);
        a[0] = 100e18;

        // Old proposer rejected
        vm.prank(users.aiProposer);
        vm.expectRevert(RewardDistributor.NotProposer.selector);
        distributor.proposeDistribution(1, c, a);

        // New proposer works
        vm.prank(newProposer);
        distributor.proposeDistribution(1, c, a);

        vm.prank(users.signer1);
        distributor.approveDistribution(1);
        vm.prank(users.signer2);
        distributor.approveDistribution(1);

        distributor.executeDistribution(1);
        assertEq(blokc.balanceOf(factory.predictContributorAccount(c[0])), 100e18);
    }

    /// @notice Cancel + re-propose: AI submits incorrect distribution,
    ///         team flags it, AI cancels and re-proposes correct one,
    ///         signers re-approve, execute succeeds.
    function test_cancelAndRepropose_correctedDistribution() public {
        address[] memory c = _createContributors(2);

        // AI accidentally submits wrong amounts
        uint256[] memory wrongA = new uint256[](2);
        wrongA[0] = 5000e18; // way too high
        wrongA[1] = 10e18;

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, wrongA);

        // Team flags — AI cancels
        vm.prank(users.aiProposer);
        distributor.cancelDistribution(1);

        // AI re-proposes with corrected amounts
        uint256[] memory correctA = new uint256[](2);
        correctA[0] = 200e18;
        correctA[1] = 300e18;

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, correctA);

        // Signers re-approve (old approvals were cleared by cancel)
        vm.prank(users.signer1);
        distributor.approveDistribution(1);
        vm.prank(users.signer2);
        distributor.approveDistribution(1);

        distributor.executeDistribution(1);

        assertEq(blokc.balanceOf(factory.predictContributorAccount(c[0])), 200e18);
        assertEq(blokc.balanceOf(factory.predictContributorAccount(c[1])), 300e18);
    }

    /// @notice Signer rotation: owner adds a 3rd signer, removes signer1.
    ///         Distribution still executes with signer2 + new signer.
    function test_signerRotation_newSignersCanApprove() public {
        address newSigner = address(0xCAFE);
        vm.startPrank(users.distributorOwner);
        distributor.addSigner(newSigner);
        distributor.removeSigner(users.signer1);
        vm.stopPrank();

        address[] memory c = _createContributors(1);
        uint256[] memory a = new uint256[](1);
        a[0] = 100e18;

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, a);

        // Old signer1 is no longer a signer
        vm.prank(users.signer1);
        vm.expectRevert(RewardDistributor.NotSigner.selector);
        distributor.approveDistribution(1);

        // signer2 and new signer can approve
        vm.prank(users.signer2);
        distributor.approveDistribution(1);
        vm.prank(newSigner);
        distributor.approveDistribution(1);

        distributor.executeDistribution(1);
        assertEq(blokc.balanceOf(factory.predictContributorAccount(c[0])), 100e18);
    }

    /// @notice Changing threshold from 2 to 3 (after adding a 3rd signer)
    ///         means 2 approvals is no longer enough.
    function test_thresholdIncrease_requiresMoreApprovals() public {
        address newSigner = address(0xCAFE);
        vm.startPrank(users.distributorOwner);
        distributor.addSigner(newSigner);
        distributor.updateThreshold(3);
        vm.stopPrank();

        address[] memory c = _createContributors(1);
        uint256[] memory a = new uint256[](1);
        a[0] = 100e18;

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, a);

        vm.prank(users.signer1);
        distributor.approveDistribution(1);
        vm.prank(users.signer2);
        distributor.approveDistribution(1);

        // Only 2 of 3 required — cannot execute
        vm.expectRevert(RewardDistributor.InsufficientApprovals.selector);
        distributor.executeDistribution(1);

        // Third signer pushes it over
        vm.prank(newSigner);
        distributor.approveDistribution(1);

        distributor.executeDistribution(1);
        assertEq(blokc.balanceOf(factory.predictContributorAccount(c[0])), 100e18);
    }

    /// @notice Distributing to accounts not yet deployed: tokens sit at
    ///         predicted addresses, captured on deploy. Verify across
    ///         multiple epochs of pre-deploy funding.
    function test_preFundMultipleEpochs_thenDeploy_capturesAll() public {
        address contributor = address(0xABCD);
        address predicted = factory.predictContributorAccount(contributor);

        address[] memory c = new address[](1);
        c[0] = contributor;

        // Epoch 1
        uint256[] memory a1 = new uint256[](1);
        a1[0] = 100e18;
        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, a1);
        vm.prank(users.signer1);
        distributor.approveDistribution(1);
        vm.prank(users.signer2);
        distributor.approveDistribution(1);
        distributor.executeDistribution(1);

        // Epoch 2
        uint256[] memory a2 = new uint256[](1);
        a2[0] = 200e18;
        vm.prank(users.aiProposer);
        distributor.proposeDistribution(2, c, a2);
        vm.prank(users.signer1);
        distributor.approveDistribution(2);
        vm.prank(users.signer2);
        distributor.approveDistribution(2);
        distributor.executeDistribution(2);

        // Tokens at bare address
        assertEq(blokc.balanceOf(predicted), 300e18);

        // Deploy — tokens captured
        vm.prank(contributor);
        factory.createContributorAccount();
        assertEq(blokc.balanceOf(predicted), 300e18);
    }
}
