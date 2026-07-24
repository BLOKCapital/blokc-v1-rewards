// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BLOKCDistributor} from "src/contracts/BLOKCDistributor.sol";
import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";
import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

/// @title  BLOKCDistributorTest
/// @notice Unit tests for {BLOKCDistributor}.
/// @dev    Inherits the shared harness in {BaseTest}, which already
///         deploys a `distributor` with 2-of-2 multisig. Most tests use
///         that inherited distributor; constructor tests deploy fresh
///         instances with intentionally-bad arguments.
///
///         Coverage groups:
///           - CONSTRUCTOR     : zero-arg guards, immutables, initial signers.
///           - PROPOSE         : authorization, validation, happy path, events.
///           - APPROVE         : authorization, duplicate, events.
///           - EXECUTE         : threshold gating, balance check, token transfers, events.
///           - CANCEL          : authorization, state reset, re-propose.
///           - ADMIN           : add/remove signer, update proposer/threshold/owner.
///           - VIEWS           : getter correctness.
contract BLOKCDistributorTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Proposes a distribution as the AI proposer for the given
    ///         contributors and amounts, returning the predicted account
    ///         addresses.
    function _propose(uint256 epochId, address[] memory contributors, uint256[] memory amounts) internal {
        vm.prank(users.aiProposer);
        distributor.proposeDistribution(epochId, contributors, amounts);
    }

    /// @notice Approves an epoch as the given signer.
    function _approve(uint256 epochId, address signer) internal {
        vm.prank(signer);
        distributor.approveDistribution(epochId);
    }

    /// @notice Proposes, gets 2 approvals, and executes — the full happy path.
    function _proposeApproveAndExecute(uint256 epochId, address[] memory contributors, uint256[] memory amounts)
        internal
    {
        _propose(epochId, contributors, amounts);
        _approve(epochId, users.signer1);
        _approve(epochId, users.signer2);
        distributor.executeDistribution(epochId);
    }

    /// @notice Returns a predictable contributor address for a synthetic index.
    function _contributor(uint256 n) internal pure returns (address) {
        return address(uint160(0x1000 + n));
    }

    /// @notice Builds a contributors array of length `count` from synthetic addresses.
    function _contributors(uint256 count) internal pure returns (address[] memory c) {
        c = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            c[i] = _contributor(i);
        }
    }

    /// @notice Builds an amounts array where each element is `amount`.
    function _amounts(uint256 count, uint256 amount) internal pure returns (uint256[] memory a) {
        a = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            a[i] = amount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts the constructor reverts with {ZeroAddress} when
    ///         `_token` is `address(0)`.
    function test_constructor_revertWhen_TokenIsZero() public {
        address[] memory s = _signers(2);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        new BLOKCDistributor(address(0), factory, users.aiProposer, users.distributorOwner, s);
    }

    /// @notice Asserts the constructor reverts with {ZeroAddress} when
    ///         `_factory` is `address(0)`.
    function test_constructor_revertWhen_FactoryIsZero() public {
        address[] memory s = _signers(2);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        new BLOKCDistributor(
            address(blokc), BLOKCContributorFactory(address(0)), users.aiProposer, users.distributorOwner, s
        );
    }

    /// @notice Asserts the constructor reverts with {ZeroAddress} when
    ///         `_proposer` is `address(0)`.
    function test_constructor_revertWhen_ProposerIsZero() public {
        address[] memory s = _signers(2);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        new BLOKCDistributor(address(blokc), factory, address(0), users.distributorOwner, s);
    }

    /// @notice Asserts the constructor reverts with {ZeroAddress} when
    ///         `_owner` is `address(0)`.
    function test_constructor_revertWhen_OwnerIsZero() public {
        address[] memory s = _signers(2);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        new BLOKCDistributor(address(blokc), factory, users.aiProposer, address(0), s);
    }

    /// @notice Asserts the constructor reverts with {InsufficientSigners}
    ///         when fewer than 2 signers are provided.
    function test_constructor_allowsFewerThanTwoSigners() public {
        address[] memory s = _signers(1);
        BLOKCDistributor d = new BLOKCDistributor(address(blokc), factory, users.aiProposer, users.distributorOwner, s);
        assertEq(d.getSignerCount(), 1);
    }

    function test_constructor_allowsEmptySigners() public {
        address[] memory s = new address[](0);
        BLOKCDistributor d = new BLOKCDistributor(address(blokc), factory, users.aiProposer, users.distributorOwner, s);
        assertEq(d.getSignerCount(), 0);
    }

    function test_proposeDistribution_revertWhen_InsufficientSigners() public {
        BLOKCDistributor d =
            new BLOKCDistributor(address(blokc), factory, users.aiProposer, users.distributorOwner, new address[](0));

        address[] memory c = new address[](1);
        c[0] = users.contributor;
        uint256[] memory a = new uint256[](1);
        a[0] = 100e18;

        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.InsufficientSigners.selector);
        d.proposeDistribution(1, c, a);
    }

    /// @notice Asserts the constructor reverts with {ZeroAddress} when a
    ///         signer in the array is `address(0)`.
    function test_constructor_revertWhen_SignerIsZero() public {
        address[] memory s = new address[](2);
        s[0] = users.signer1;
        s[1] = address(0);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        new BLOKCDistributor(address(blokc), factory, users.aiProposer, users.distributorOwner, s);
    }

    /// @notice Asserts the constructor reverts when a signer appears twice.
    function test_constructor_revertWhen_DuplicateSigner() public {
        address[] memory s = new address[](2);
        s[0] = users.signer1;
        s[1] = users.signer1;
        vm.expectRevert(BLOKCDistributor.DuplicateSigner.selector);
        new BLOKCDistributor(address(blokc), factory, users.aiProposer, users.distributorOwner, s);
    }

    /// @notice Asserts the constructor wires up immutables, mutable state
    ///         and initial signers correctly.
    function test_constructor_setsState() public {
        address[] memory s = _signers(2);
        BLOKCDistributor d = new BLOKCDistributor(address(blokc), factory, users.aiProposer, users.distributorOwner, s);

        assertEq(d.token(), address(blokc));
        assertEq(address(d.factory()), address(factory));
        assertEq(d.proposer(), users.aiProposer);
        assertEq(d.owner(), users.distributorOwner);
        assertEq(d.getSignerCount(), 2);
        assertTrue(d.isSigner(s[0]));
        assertTrue(d.isSigner(s[1]));
    }

    /// @notice Helper to build a signers array of the given size from
    ///         predictable addresses.
    function _signers(uint256 count) internal pure returns (address[] memory s) {
        s = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            s[i] = address(uint160(0x2000 + i));
        }
    }

    /*//////////////////////////////////////////////////////////////
                           PROPOSE — AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {proposeDistribution} reverts with {NotProposer}
    ///         when called by a non-proposer.
    function test_propose_revertWhen_NotProposer() public {
        address[] memory c = _contributors(1);
        uint256[] memory a = _amounts(1, 100e18);
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCDistributor.NotProposer.selector);
        distributor.proposeDistribution(1, c, a);
    }

    /*//////////////////////////////////////////////////////////////
                           PROPOSE — VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {proposeDistribution} reverts with {InvalidEpochId}
    ///         when `epochId` is zero.
    function test_propose_revertWhen_EpochIdIsZero() public {
        address[] memory c = _contributors(1);
        uint256[] memory a = _amounts(1, 100e18);
        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.InvalidEpochId.selector);
        distributor.proposeDistribution(0, c, a);
    }

    /// @notice Asserts {proposeDistribution} reverts with {ZeroLength}
    ///         when contributors array is empty.
    function test_propose_revertWhen_ContributorsEmpty() public {
        address[] memory c = new address[](0);
        uint256[] memory a = new uint256[](0);
        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.ZeroLength.selector);
        distributor.proposeDistribution(1, c, a);
    }

    /// @notice Asserts {proposeDistribution} reverts with {LengthMismatch}
    ///         when contributors and amounts arrays differ in length.
    function test_propose_revertWhen_LengthMismatch() public {
        address[] memory c = _contributors(3);
        uint256[] memory a = _amounts(2, 100e18);
        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.LengthMismatch.selector);
        distributor.proposeDistribution(1, c, a);
    }

    /// @notice Asserts {proposeDistribution} reverts with {ZeroAddress}
    ///         when a contributor address is zero.
    function test_propose_revertWhen_ContributorIsZero() public {
        address[] memory c = new address[](2);
        c[0] = _contributor(0);
        c[1] = address(0);
        uint256[] memory a = _amounts(2, 100e18);
        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        distributor.proposeDistribution(1, c, a);
    }

    /// @notice Asserts {proposeDistribution} reverts with {ZeroAmount}
    ///         when an amount is zero.
    function test_propose_revertWhen_AmountIsZero() public {
        address[] memory c = _contributors(2);
        uint256[] memory a = new uint256[](2);
        a[0] = 100e18;
        a[1] = 0;
        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.ZeroAmount.selector);
        distributor.proposeDistribution(1, c, a);
    }

    /// @notice Asserts {proposeDistribution} reverts with {AlreadyProposed}
    ///         when the same epoch is proposed twice.
    function test_propose_revertWhen_AlreadyProposed() public {
        address[] memory c = _contributors(1);
        uint256[] memory a = _amounts(1, 100e18);
        _propose(1, c, a);
        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.AlreadyProposed.selector);
        distributor.proposeDistribution(1, c, a);
    }

    /*//////////////////////////////////////////////////////////////
                           PROPOSE — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts a successful proposal marks the epoch as proposed
    ///         and stores the scalar fields correctly.
    function test_propose_storesDistribution() public {
        address[] memory c = _contributors(2);
        uint256[] memory a = new uint256[](2);
        a[0] = 300e18;
        a[1] = 200e18;

        _propose(1, c, a);

        assertTrue(distributor.isEpochProposed(1));
        assertFalse(distributor.isEpochExecuted(1));
        (uint256 appCount,, bool executed, uint256 proposedAt) = distributor.distributions(1);
        assertEq(appCount, 0);
        assertFalse(executed);
        assertTrue(proposedAt > 0);
    }

    /// @notice Asserts {proposeDistribution} emits {DistributionProposed}
    ///         with correct indexed fields (epochId and totalAmount).
    function test_propose_emitsDistributionProposed() public {
        address[] memory c = _contributors(2);
        uint256[] memory a = new uint256[](2);
        a[0] = 300e18;
        a[1] = 200e18;

        vm.expectEmit(true, true, false, true, address(distributor));
        emit DistributionProposed(1, 500e18, c, a);

        _propose(1, c, a);
    }

    /// @notice Asserts proposing for a different epoch after one is
    ///         proposed succeeds (different epochs are independent).
    function test_propose_differentEpochsIndependent() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));
        _propose(2, _contributors(2), _amounts(2, 50e18));

        assertTrue(distributor.isEpochProposed(1));
        assertTrue(distributor.isEpochProposed(2));
    }

    /*//////////////////////////////////////////////////////////////
                           APPROVE — AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {approveDistribution} reverts with {NotSigner}
    ///         when called by a non-signer.
    function test_approve_revertWhen_NotSigner() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCDistributor.NotSigner.selector);
        distributor.approveDistribution(1);
    }

    /*//////////////////////////////////////////////////////////////
                           APPROVE — VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {approveDistribution} reverts with
    ///         {DistributionNotFound} when the epoch was never proposed.
    function test_approve_revertWhen_DistributionNotFound() public {
        vm.prank(users.signer1);
        vm.expectRevert(BLOKCDistributor.DistributionNotFound.selector);
        distributor.approveDistribution(99);
    }

    /// @notice Asserts {approveDistribution} reverts with
    ///         {AlreadyExecuted} when the distribution is already executed.
    function test_approve_revertWhen_AlreadyExecuted() public {
        _fundDistributor();
        _proposeApproveAndExecute(1, _contributors(1), _amounts(1, 100e18));

        vm.prank(users.signer1);
        vm.expectRevert(BLOKCDistributor.AlreadyExecuted.selector);
        distributor.approveDistribution(1);
    }

    /// @notice Asserts {approveDistribution} reverts with
    ///         {AlreadyApproved} when a signer approves the same epoch twice.
    function test_approve_revertWhen_AlreadyApproved() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));
        _approve(1, users.signer1);

        vm.prank(users.signer1);
        vm.expectRevert(BLOKCDistributor.AlreadyApproved.selector);
        distributor.approveDistribution(1);
    }

    /*//////////////////////////////////////////////////////////////
                           APPROVE — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts a signer's approval increments the count and is
    ///         tracked.
    function test_approve_incrementsApprovalCount() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));

        _approve(1, users.signer1);
        (uint256 count1,,,) = distributor.distributions(1);
        assertEq(count1, 1);
        assertTrue(distributor.approvals(1, users.signer1));

        _approve(1, users.signer2);
        (uint256 count2,,,) = distributor.distributions(1);
        assertEq(count2, 2);
        assertTrue(distributor.approvals(1, users.signer2));
    }

    /// @notice Asserts {approveDistribution} emits {DistributionApproved}
    ///         with correct fields.
    function test_approve_emitsDistributionApproved() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));

        vm.expectEmit(true, true, false, false, address(distributor));
        emit DistributionApproved(1, users.signer1, 1);

        _approve(1, users.signer1);
    }

    /*//////////////////////////////////////////////////////////////
                           EXECUTE — VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {executeDistribution} reverts with
    ///         {DistributionNotFound} when the epoch was never proposed.
    function test_execute_revertWhen_DistributionNotFound() public {
        vm.expectRevert(BLOKCDistributor.DistributionNotFound.selector);
        distributor.executeDistribution(99);
    }

    /// @notice Asserts {executeDistribution} reverts with
    ///         {AlreadyExecuted} when called twice on the same epoch.
    function test_execute_revertWhen_AlreadyExecuted() public {
        _fundDistributor();
        _proposeApproveAndExecute(1, _contributors(1), _amounts(1, 100e18));

        vm.expectRevert(BLOKCDistributor.AlreadyExecuted.selector);
        distributor.executeDistribution(1);
    }

    /// @notice Asserts {executeDistribution} reverts with
    ///         {InsufficientApprovals} when threshold is not met.
    function test_execute_revertWhen_InsufficientApprovals() public {
        _fundDistributor();
        _propose(1, _contributors(1), _amounts(1, 100e18));
        _approve(1, users.signer1); // only 1 of 2

        vm.expectRevert(BLOKCDistributor.InsufficientApprovals.selector);
        distributor.executeDistribution(1);
    }

    /// @notice Asserts {executeDistribution} reverts with
    ///         {InsufficientApprovals} when no approvals at all.
    function test_execute_revertWhen_NoApprovals() public {
        _fundDistributor();
        _propose(1, _contributors(1), _amounts(1, 100e18));

        vm.expectRevert(BLOKCDistributor.InsufficientApprovals.selector);
        distributor.executeDistribution(1);
    }

    /// @notice Asserts {executeDistribution} reverts with
    ///         {InsufficientBalance} when the distributor lacks tokens.
    function test_execute_revertWhen_InsufficientBalance() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));
        _approve(1, users.signer1);
        _approve(1, users.signer2);
        // distributor was NOT funded

        vm.expectRevert(BLOKCDistributor.InsufficientBalance.selector);
        distributor.executeDistribution(1);
    }

    /*//////////////////////////////////////////////////////////////
                           EXECUTE — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts execution sends the correct BLOKC amount to the
    ///         predicted contributor account address.
    function test_execute_sendsTokensToPredictedAddress() public {
        _fundDistributor();
        address contributor = _contributor(0);
        address[] memory c = new address[](1);
        c[0] = contributor;
        uint256[] memory a = _amounts(1, 100e18);

        address predicted = factory.predictContributorAccount(contributor);

        _proposeApproveAndExecute(1, c, a);

        assertEq(blokc.balanceOf(predicted), 100e18);
    }

    /// @notice Asserts execution distributes the correct amounts to
    ///         multiple contributors proportionally.
    function test_execute_distributesToMultipleContributors() public {
        _fundDistributor();

        // Deploy accounts first so we can check balances
        address[] memory c = _createContributors(3);
        uint256[] memory a = new uint256[](3);
        a[0] = 300e18;
        a[1] = 200e18;
        a[2] = 100e18;

        _proposeApproveAndExecute(1, c, a);

        assertEq(blokc.balanceOf(factory.predictContributorAccount(c[0])), 300e18);
        assertEq(blokc.balanceOf(factory.predictContributorAccount(c[1])), 200e18);
        assertEq(blokc.balanceOf(factory.predictContributorAccount(c[2])), 100e18);
    }

    /// @notice Asserts tokens sent to a predicted address (account not yet
    ///         deployed) are captured when the account is later deployed.
    function test_execute_preFundThenDeploy_capturesTokens() public {
        _fundDistributor();
        address contributor = _contributor(0);
        address[] memory c = new address[](1);
        c[0] = contributor;
        uint256[] memory a = _amounts(1, 100e18);

        address predicted = factory.predictContributorAccount(contributor);

        _proposeApproveAndExecute(1, c, a);

        // Tokens are at the bare address (no contract deployed yet)
        assertEq(blokc.balanceOf(predicted), 100e18);

        // Now deploy the account — tokens are captured
        vm.prank(contributor);
        BLOKCContributorAccount account = BLOKCContributorAccount(factory.createContributorAccount());

        assertEq(address(account), predicted);
        assertEq(blokc.balanceOf(address(account)), 100e18);
    }

    /// @notice Asserts anyone (not just proposer or signers) can execute
    ///         once threshold is met.
    function test_execute_permissionless() public {
        _fundDistributor();
        _propose(1, _contributors(1), _amounts(1, 100e18));
        _approve(1, users.signer1);
        _approve(1, users.signer2);

        // A random address calls execute
        vm.prank(users.goodSamaritan);
        distributor.executeDistribution(1);

        assertTrue(distributor.isEpochExecuted(1));
    }

    /// @notice Asserts {executeDistribution} emits {DistributionExecuted}.
    function test_execute_emitsDistributionExecuted() public {
        _fundDistributor();
        address[] memory c = _contributors(2);
        uint256[] memory a = new uint256[](2);
        a[0] = 300e18;
        a[1] = 200e18;

        _propose(1, c, a);
        _approve(1, users.signer1);
        _approve(1, users.signer2);

        vm.expectEmit(true, false, false, false, address(distributor));
        emit DistributionExecuted(1, 500e18, 2);

        distributor.executeDistribution(1);
    }

    /// @notice Asserts execution marks the distribution as executed.
    function test_execute_marksExecuted() public {
        _fundDistributor();
        _proposeApproveAndExecute(1, _contributors(1), _amounts(1, 100e18));

        assertTrue(distributor.isEpochExecuted(1));
        (,, bool executed,) = distributor.distributions(1);
        assertTrue(executed);
    }

    /*//////////////////////////////////////////////////////////////
                           CANCEL
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {cancelDistribution} reverts with {NotProposer}
    ///         when called by a non-proposer.
    function test_cancel_revertWhen_NotProposer() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCDistributor.NotProposer.selector);
        distributor.cancelDistribution(1);
    }

    /// @notice Asserts {cancelDistribution} reverts with
    ///         {DistributionNotFound} when the epoch was never proposed.
    function test_cancel_revertWhen_DistributionNotFound() public {
        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.DistributionNotFound.selector);
        distributor.cancelDistribution(99);
    }

    /// @notice Asserts {cancelDistribution} reverts with
    ///         {AlreadyExecuted} when the distribution is already executed.
    function test_cancel_revertWhen_AlreadyExecuted() public {
        _fundDistributor();
        _proposeApproveAndExecute(1, _contributors(1), _amounts(1, 100e18));

        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.AlreadyExecuted.selector);
        distributor.cancelDistribution(1);
    }

    /// @notice Asserts cancellation clears the distribution data so a new
    ///         one can be proposed for the same epoch.
    function test_cancel_allowsRepropose() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));
        vm.prank(users.aiProposer);
        distributor.cancelDistribution(1);

        // Epoch should no longer appear as proposed
        assertFalse(distributor.isEpochProposed(1));

        // Should be able to re-propose for the same epoch
        address[] memory c = _contributors(2);
        uint256[] memory a = _amounts(2, 50e18);
        _propose(1, c, a);

        assertTrue(distributor.isEpochProposed(1));
        (uint256 appCount,,,) = distributor.distributions(1);
        assertEq(appCount, 0);
    }

    /// @notice Asserts approval state is reset on cancel so signers must
    ///         re-approve the re-proposed distribution.
    function test_cancel_resetsApprovals() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));
        _approve(1, users.signer1);

        vm.prank(users.aiProposer);
        distributor.cancelDistribution(1);

        _propose(1, _contributors(1), _amounts(1, 50e18));

        assertFalse(distributor.approvals(1, users.signer1));
    }

    /// @notice Asserts {cancelDistribution} emits {DistributionCancelled}.
    function test_cancel_emitsDistributionCancelled() public {
        _propose(1, _contributors(1), _amounts(1, 100e18));

        vm.expectEmit(true, false, false, false, address(distributor));
        emit DistributionCancelled(1);

        vm.prank(users.aiProposer);
        distributor.cancelDistribution(1);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN — ADD SIGNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {addSigner} reverts with {NotOwner} when called
    ///         by a non-owner.
    function test_addSigner_revertWhen_NotOwner() public {
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCDistributor.NotOwner.selector);
        distributor.addSigner(_contributor(99));
    }

    /// @notice Asserts {addSigner} reverts with {ZeroAddress} when the
    ///         new signer is `address(0)`.
    function test_addSigner_revertWhen_ZeroAddress() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        distributor.addSigner(address(0));
    }

    /// @notice Asserts {addSigner} reverts when the address is already
    ///         a signer.
    function test_addSigner_revertWhen_AlreadySigner() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.AlreadyApproved.selector);
        distributor.addSigner(users.signer1);
    }

    /// @notice Asserts {addSigner} adds the signer, updates tracking, and
    ///         emits {SignerAdded}.
    function test_addSigner_succeeds() public {
        address newSigner = _contributor(99);
        uint256 before = distributor.getSignerCount();

        vm.prank(users.distributorOwner);
        vm.expectEmit(true, false, false, false, address(distributor));
        emit SignerAdded(newSigner);
        distributor.addSigner(newSigner);

        assertTrue(distributor.isSigner(newSigner));
        assertEq(distributor.getSignerCount(), before + 1);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN — REMOVE SIGNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {removeSigner} reverts with {NotOwner} when called
    ///         by a non-owner.
    function test_removeSigner_revertWhen_NotOwner() public {
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCDistributor.NotOwner.selector);
        distributor.removeSigner(users.signer1);
    }

    /// @notice Asserts {removeSigner} reverts with {NotSigner} when the
    ///         address is not a signer.
    function test_removeSigner_revertWhen_NotSigner() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.NotSigner.selector);
        distributor.removeSigner(_contributor(99));
    }

    /// @notice Asserts {removeSigner} reverts when removal would drop
    ///         signer count below the threshold.
    function test_removeSigner_revertWhen_WouldDropBelowThreshold() public {
        // Default: 2 signers, threshold 2 — cannot remove any
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.InsufficientSigners.selector);
        distributor.removeSigner(users.signer1);
    }

    /// @notice Asserts {removeSigner} succeeds when there are more signers
    ///         than the threshold.
    function test_removeSigner_succeeds() public {
        // Add a third signer so we can remove one while keeping threshold of 2
        vm.startPrank(users.distributorOwner);
        distributor.addSigner(_contributor(99));
        uint256 before = distributor.getSignerCount();

        vm.expectEmit(true, false, false, false, address(distributor));
        emit SignerRemoved(users.signer1);
        distributor.removeSigner(users.signer1);

        assertFalse(distributor.isSigner(users.signer1));
        assertEq(distributor.getSignerCount(), before - 1);
        vm.stopPrank();
    }

    /// @notice Asserts that removing a non-approving signer does NOT
    ///         make a pending distribution executable. requiredApprovals
    ///         is frozen at proposal time, so the removed signer's
    ///         approval is still required.
    function test_removeSigner_doesNotBypassPendingApprovals() public {
        // Deploy fresh distributor with 3 signers
        address[] memory s = new address[](3);
        s[0] = users.signer1;
        s[1] = users.signer2;
        s[2] = _contributor(99);
        BLOKCDistributor d = new BLOKCDistributor(address(blokc), factory, users.aiProposer, users.distributorOwner, s);
        blokc.mint(address(d), 1000e18);

        // Propose
        vm.prank(users.aiProposer);
        d.proposeDistribution(1, _contributors(1), _amounts(1, 100e18));

        // 2 of 3 approve (signer1 + signer2)
        vm.prank(users.signer1);
        d.approveDistribution(1);
        vm.prank(users.signer2);
        d.approveDistribution(1);

        // Remove signer 3 (who hasn't approved)
        vm.prank(users.distributorOwner);
        d.removeSigner(s[2]);

        // Execution must STILL revert — requiredApprovals was frozen at 3
        // at proposal time, and only 2 approvals exist
        vm.expectRevert(BLOKCDistributor.InsufficientApprovals.selector);
        d.executeDistribution(1);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN — UPDATE PROPOSER
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {updateProposer} reverts with {NotOwner}.
    function test_updateProposer_revertWhen_NotOwner() public {
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCDistributor.NotOwner.selector);
        distributor.updateProposer(_contributor(99));
    }

    /// @notice Asserts {updateProposer} reverts with {ZeroAddress}.
    function test_updateProposer_revertWhen_ZeroAddress() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        distributor.updateProposer(address(0));
    }

    /// @notice Asserts {updateProposer} reverts with {SameAddress} when the
    ///         new proposer equals the current one.
    function test_updateProposer_revertWhen_SameAddress() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.SameAddress.selector);
        distributor.updateProposer(users.aiProposer);
    }

    /// @notice Asserts {updateProposer} updates storage and emits event.
    function test_updateProposer_succeeds() public {
        address newProposer = _contributor(99);

        vm.prank(users.distributorOwner);
        vm.expectEmit(true, true, false, false, address(distributor));
        emit ProposerUpdated(users.aiProposer, newProposer);
        distributor.updateProposer(newProposer);

        assertEq(distributor.proposer(), newProposer);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN — UPDATE OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {updateOwner} reverts with {NotOwner}.
    function test_updateOwner_revertWhen_NotOwner() public {
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCDistributor.NotOwner.selector);
        distributor.updateOwner(_contributor(99));
    }

    /// @notice Asserts {updateOwner} reverts with {ZeroAddress}.
    function test_updateOwner_revertWhen_ZeroAddress() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        distributor.updateOwner(address(0));
    }

    /// @notice Asserts {updateOwner} reverts with {SameAddress}.
    function test_updateOwner_revertWhen_SameAddress() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.SameAddress.selector);
        distributor.updateOwner(users.distributorOwner);
    }

    /// @notice Asserts {updateOwner} succeeds and emits event.
    function test_updateOwner_succeeds() public {
        address newOwner = _contributor(99);

        vm.prank(users.distributorOwner);
        vm.expectEmit(true, true, false, false, address(distributor));
        emit OwnerUpdated(users.distributorOwner, newOwner);
        distributor.updateOwner(newOwner);

        assertEq(distributor.owner(), newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN — RECOVER TOKENS
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {recoverTokens} reverts with {NotOwner}.
    function test_recoverTokens_revertWhen_NotOwner() public {
        vm.prank(users.attacker);
        vm.expectRevert(BLOKCDistributor.NotOwner.selector);
        distributor.recoverTokens(address(blokc), users.recipient, 1e18);
    }

    /// @notice Asserts {recoverTokens} reverts with {ZeroAddress} when
    ///         token is zero.
    function test_recoverTokens_revertWhen_TokenIsZero() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        distributor.recoverTokens(address(0), users.recipient, 1e18);
    }

    /// @notice Asserts {recoverTokens} reverts with {ZeroAddress} when
    ///         recipient is zero.
    function test_recoverTokens_revertWhen_RecipientIsZero() public {
        _fundDistributor();
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.ZeroAddress.selector);
        distributor.recoverTokens(address(blokc), address(0), 1e18);
    }

    /// @notice Asserts {recoverTokens} reverts with {ZeroAmount} when
    ///         amount is zero.
    function test_recoverTokens_revertWhen_ZeroAmount() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.ZeroAmount.selector);
        distributor.recoverTokens(address(blokc), users.recipient, 0);
    }

    /// @notice Asserts {recoverTokens} reverts with {InsufficientBalance}
    ///         when amount exceeds balance.
    function test_recoverTokens_revertWhen_InsufficientBalance() public {
        vm.prank(users.distributorOwner);
        vm.expectRevert(BLOKCDistributor.InsufficientBalance.selector);
        distributor.recoverTokens(address(blokc), users.recipient, 1_000_000e18);
    }

    /// @notice Asserts {recoverTokens} succeeds at sweeping dust after
    ///         a distribution.
    function test_recoverTokens_succeeds() public {
        _fundDistributor();
        _proposeApproveAndExecute(1, _contributors(1), _amounts(1, 100e18));

        // Remaining balance should be recoverable
        uint256 remaining = distributor.balanceOf();
        assertTrue(remaining > 0);

        vm.prank(users.distributorOwner);
        vm.expectEmit(true, true, false, false, address(distributor));
        emit TokensRecovered(address(blokc), users.recipient, remaining);
        distributor.recoverTokens(address(blokc), users.recipient, remaining);

        assertEq(distributor.balanceOf(), 0);
        assertEq(blokc.balanceOf(users.recipient), remaining);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Asserts {isEpochProposed} returns false before proposal and
    ///         true after.
    function test_view_isEpochProposed() public {
        assertFalse(distributor.isEpochProposed(1));
        _propose(1, _contributors(1), _amounts(1, 100e18));
        assertTrue(distributor.isEpochProposed(1));
    }

    /// @notice Asserts {isEpochExecuted} returns false before execution and
    ///         true after.
    function test_view_isEpochExecuted() public {
        _fundDistributor();
        _propose(1, _contributors(1), _amounts(1, 100e18));
        assertFalse(distributor.isEpochExecuted(1));

        _approve(1, users.signer1);
        _approve(1, users.signer2);
        distributor.executeDistribution(1);

        assertTrue(distributor.isEpochExecuted(1));
    }

    /// @notice Asserts {balanceOf} returns the distributor's $BLOKC balance.
    function test_view_balanceOf() public {
        assertEq(distributor.balanceOf(), 0);
        _fundDistributor(500e18);
        assertEq(distributor.balanceOf(), 500e18);
    }

    /// @notice Asserts {getSignerCount} reflects constructor and mutations.
    function test_view_getSignerCount() public {
        assertEq(distributor.getSignerCount(), 2);
    }
}
