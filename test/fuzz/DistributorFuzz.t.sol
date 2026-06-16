// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BLOKCDistributor} from "src/contracts/BLOKCDistributor.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

/// @title  DistributorFuzzTest
/// @notice Fuzz tests for {BLOKCDistributor} covering edge cases on
///         amounts, thresholds, and approval ordering.
contract DistributorFuzzTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _fundDistributor();
    }

    /// @notice Asserts that for any non-zero epochId, distributing twice
    ///         reverts with {AlreadyProposed}.
    function testFuzz_propose_sameEpochTwiceReverts(uint256 epochId) public {
        vm.assume(epochId != 0);

        address[] memory c = _createContributors(1);
        uint256[] memory a = new uint256[](1);
        a[0] = 100e18;

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(epochId, c, a);

        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.AlreadyProposed.selector);
        distributor.proposeDistribution(epochId, c, a);
    }

    /// @notice Asserts that for any set of valid scores, the total
    ///         distributed (sum of individual account balances) does not
    ///         exceed the total amount in the distribution.
    function testFuzz_execute_conservation(uint256 amountA, uint256 amountB) public {
        amountA = bound(amountA, 1e18, 10_000e18);
        amountB = bound(amountB, 1e18, 10_000e18);

        // Ensure distributor has enough
        _fundDistributor(amountA + amountB + 100e18);

        address[] memory c = _createContributors(2);
        uint256[] memory a = new uint256[](2);
        a[0] = amountA;
        a[1] = amountB;

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, a);
        vm.prank(users.signer1);
        distributor.approveDistribution(1);
        vm.prank(users.signer2);
        distributor.approveDistribution(1);
        distributor.executeDistribution(1);

        uint256 receivedA = blokc.balanceOf(factory.predictContributorAccount(c[0]));
        uint256 receivedB = blokc.balanceOf(factory.predictContributorAccount(c[1]));

        assertEq(receivedA, amountA);
        assertEq(receivedB, amountB);
        assertEq(receivedA + receivedB, amountA + amountB);
    }

    /// @notice Asserts that a zero-score contributor gets nothing regardless
    ///         of the other contributor's score.
    function testFuzz_propose_zeroAmountReverts(uint256 validAmount) public {
        validAmount = bound(validAmount, 1e18, 10_000e18);

        address[] memory c = _createContributors(2);
        uint256[] memory a = new uint256[](2);
        a[0] = validAmount;
        a[1] = 0;

        vm.prank(users.aiProposer);
        vm.expectRevert(BLOKCDistributor.ZeroAmount.selector);
        distributor.proposeDistribution(1, c, a);
    }

    /// @notice Asserts that approval ordering doesn't matter — any
    ///         permutation of signers approving in any order yields the
    ///         same approval count.
    function testFuzz_approve_anyOrder(uint8 signerOrder) public {
        address[] memory c = _createContributors(1);
        uint256[] memory a = new uint256[](1);
        a[0] = 100e18;

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, a);

        if (signerOrder % 2 == 0) {
            _approveAs(1, users.signer1);
            _approveAs(1, users.signer2);
        } else {
            _approveAs(1, users.signer2);
            _approveAs(1, users.signer1);
        }

        (uint256 count,,) = distributor.distributions(1);
        assertEq(count, 2);

        distributor.executeDistribution(1);
        assertTrue(distributor.isEpochExecuted(1));
    }

    /// @notice Asserts cancel then re-propose works for any amount.
    function testFuzz_cancelRepropose_anyAmount(uint256 amount) public {
        amount = bound(amount, 1e18, 10_000e18);

        address[] memory c = _createContributors(1);
        uint256[] memory a1 = new uint256[](1);
        a1[0] = amount * 2; // wrong amount

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, a1);

        vm.prank(users.aiProposer);
        distributor.cancelDistribution(1);

        uint256[] memory a2 = new uint256[](1);
        a2[0] = amount; // corrected

        vm.prank(users.aiProposer);
        distributor.proposeDistribution(1, c, a2);

        vm.prank(users.signer1);
        distributor.approveDistribution(1);
        vm.prank(users.signer2);
        distributor.approveDistribution(1);

        distributor.executeDistribution(1);
        assertEq(blokc.balanceOf(factory.predictContributorAccount(c[0])), amount);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _approveAs(uint256 epochId, address signer) internal {
        vm.prank(signer);
        distributor.approveDistribution(epochId);
    }
}
