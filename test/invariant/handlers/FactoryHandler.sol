// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";

/// @notice Bounded handler that drives `BLOKCContributorFactory` for use
///         by `FactoryInvariant.t.sol`. Picks contributors from a fixed
///         pool so the fuzzer can repeatedly hit the same contributor
///         and exercise the idempotent short-circuit.
///
/// @dev    Ghost variables let invariants verify registry coherence
///         without re-deriving counts from the factory itself:
///           - `g_seenContributors`     — every contributor the handler has
///                                       attempted creation for
///           - `g_isSeen`              — membership lookup for the above
///           - `g_uniqueContributors`   — distinct contributor count
///           - `g_createCalls`         — total create calls (incl. idempotent)
///           - `g_lastReturned`        — last-returned account address per
///                                       contributor, to detect address drift
contract FactoryHandler is CommonBase, StdCheats, StdUtils {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    BLOKCContributorFactory public factory;
    address[] public contributorPool;

    address[] public g_seenContributors;
    mapping(address => bool) public g_isSeen;
    uint256 public g_uniqueContributors;
    uint256 public g_createCalls;
    mapping(address => address) public g_lastReturned;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(BLOKCContributorFactory _factory, address[] memory _contributorPool) {
        factory = _factory;
        contributorPool = _contributorPool;
    }

    /*//////////////////////////////////////////////////////////////
                              HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create-or-return for a contributor from the bounded pool.
    ///         Only the contributor themselves can create their account,
    ///         so we prank as them.
    function createForPoolMember(uint256 idx) external {
        if (contributorPool.length == 0) return;
        address contributor = contributorPool[idx % contributorPool.length];

        vm.prank(contributor);
        address returned = factory.createContributorAccount();

        if (!g_isSeen[contributor]) {
            g_isSeen[contributor] = true;
            g_seenContributors.push(contributor);
            g_uniqueContributors++;
        }
        g_lastReturned[contributor] = returned;
        g_createCalls++;
    }

    /// @notice Pick an already-created contributor and create again, to
    ///         force the idempotent short-circuit path.
    function createAgainForExisting(uint256 idx) external {
        if (g_seenContributors.length == 0) return;
        address contributor = g_seenContributors[idx % g_seenContributors.length];

        vm.prank(contributor);
        address returned = factory.createContributorAccount();

        // Address must not drift across idempotent calls.
        require(returned == g_lastReturned[contributor], "FactoryHandler: address drift");
        g_createCalls++;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function seenContributorsLength() external view returns (uint256) {
        return g_seenContributors.length;
    }
}
