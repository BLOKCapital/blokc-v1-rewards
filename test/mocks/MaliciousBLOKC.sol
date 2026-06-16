// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {RewardDistributor} from "src/contracts/RewardDistributor.sol";

/// @notice Malicious $BLOKC token used to verify the distributor's
///         reentrancy protections during {executeDistribution}.
///
/// @dev    During `transfer`, this token calls back into the
///         distributor's {executeDistribution} to attempt re-execution
///         of an already-completed distribution. The distributor's CEI
///         pattern (marking `executed = true` before transfers) should
///         block the reentrant call with {AlreadyExecuted}.
contract MaliciousBLOKC is ERC20, ERC20Votes {
    /// @notice The distributor to re-enter.
    RewardDistributor public distributor;

    /// @notice The epoch to re-enter with.
    uint256 public reenterEpoch;

    /// @notice Whether reentry mode is active.
    bool public reenter;

    constructor() ERC20("Malicious BLOKC", "MBLOKC") EIP712("Malicious BLOKC", "1") {}

    function setReentryTarget(RewardDistributor _distributor, uint256 _epochId) external {
        distributor = _distributor;
        reenterEpoch = _epochId;
    }

    function setReenter(bool _reenter) external {
        reenter = _reenter;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override(ERC20) returns (bool) {
        if (reenter && address(distributor) != address(0)) {
            // Attempt to re-enter executeDistribution. This must revert
            // because the distributor sets `executed = true` before
            // the first transfer (CEI).
            distributor.executeDistribution(reenterEpoch);
        }
        return super.transfer(to, amount);
    }

    /// @dev Required override — both ERC20 and ERC20Votes declare `_update`.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
