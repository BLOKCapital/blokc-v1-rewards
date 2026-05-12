// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {BLOKCAmbassadorFactory} from "src/contracts/factory/BLOKCAmbassadorFactory.sol";

/// @notice Bounded handler that drives `BLOKCAmbassadorFactory` for use
///         by `FactoryInvariant.t.sol`. Picks ambassadors from a fixed
///         pool so the fuzzer can repeatedly hit the same ambassador
///         and exercise the idempotent short-circuit.
///
/// @dev    Ghost variables let invariants verify registry coherence
///         without re-deriving counts from the factory itself:
///           - `g_seenAmbassadors`     — every ambassador the handler has
///                                       attempted creation for
///           - `g_isSeen`              — membership lookup for the above
///           - `g_uniqueAmbassadors`   — distinct ambassador count
///           - `g_createCalls`         — total create calls (incl. idempotent)
///           - `g_lastReturned`        — last-returned account address per
///                                       ambassador, to detect address drift
contract FactoryHandler is CommonBase, StdCheats, StdUtils {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    BLOKCAmbassadorFactory public factory;
    address[] public ambassadorPool;

    address[] public g_seenAmbassadors;
    mapping(address => bool) public g_isSeen;
    uint256 public g_uniqueAmbassadors;
    uint256 public g_createCalls;
    mapping(address => address) public g_lastReturned;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(BLOKCAmbassadorFactory _factory, address[] memory _ambassadorPool) {
        factory = _factory;
        ambassadorPool = _ambassadorPool;
    }

    /*//////////////////////////////////////////////////////////////
                              HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create-or-return for `ambassador`, picked from the bounded
    ///         pool. Pranks as the ambassador half the time and as a
    ///         random "good samaritan" the other half, so both factory
    ///         overload semantics get exercised — but always via the
    ///         address-arg overload so the assertion is "bound to the
    ///         arg, not the caller".
    function createForPoolMember(uint256 idx, uint256 callerSeed) external {
        if (ambassadorPool.length == 0) return;
        address ambassador = ambassadorPool[idx % ambassadorPool.length];
        address caller =
            (callerSeed & 1 == 0) ? ambassador : address(uint160(uint256(keccak256(abi.encode(callerSeed)))));
        if (caller == address(0)) caller = ambassador;

        vm.prank(caller);
        address returned = factory.createAmbassadorAccount(ambassador);

        if (!g_isSeen[ambassador]) {
            g_isSeen[ambassador] = true;
            g_seenAmbassadors.push(ambassador);
            g_uniqueAmbassadors++;
        }
        g_lastReturned[ambassador] = returned;
        g_createCalls++;
    }

    /// @notice Pick an already-created ambassador and create again, to
    ///         force the idempotent short-circuit path.
    function createAgainForExisting(uint256 idx) external {
        if (g_seenAmbassadors.length == 0) return;
        address ambassador = g_seenAmbassadors[idx % g_seenAmbassadors.length];

        vm.prank(ambassador);
        address returned = factory.createAmbassadorAccount();

        // Address must not drift across idempotent calls.
        require(returned == g_lastReturned[ambassador], "FactoryHandler: address drift");
        g_createCalls++;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function seenAmbassadorsLength() external view returns (uint256) {
        return g_seenAmbassadors.length;
    }
}
