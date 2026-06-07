// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";

/// @notice Mis-behaving ERC20 used to exercise the `recoverERC20` path
///         in `BLOKCContributorAccount`. Toggle one of the failure modes
///         before calling the function under test.
///
/// @dev    Modes covered:
///         - `mode == None`: behaves like a normal ERC20 (control case)
///         - `mode == ReturnFalse`: `transfer` returns `false`
///                                   (must be caught by SafeERC20)
///         - `mode == Revert`:      `transfer` reverts unconditionally
///         - `mode == ReenterRecover`: during `transfer`, calls back into
///                                   the account's `recoverERC20` to try
///                                   to re-execute the recovery. The
///                                   account is not reentrancy-guarded;
///                                   the test asserts whatever current
///                                   behaviour is (typically: insufficient
///                                   balance on second call).
contract MaliciousERC20 is ERC20 {
    enum Mode {
        None,
        ReturnFalse,
        Revert,
        ReenterRecover
    }

    Mode public mode;

    /// @notice Account targeted for reentry. Set before triggering a
    ///         `ReenterRecover` mode call.
    BLOKCContributorAccount public target;

    /// @notice Recipient passed by the malicious reentry call.
    address public reentryRecipient;

    /// @notice Amount passed by the malicious reentry call.
    uint256 public reentryAmount;

    constructor() ERC20("Malicious", "EVIL") {}

    function setMode(Mode _mode) external {
        mode = _mode;
    }

    function setReentryTarget(BLOKCContributorAccount _target, address _recipient, uint256 _amount) external {
        target = _target;
        reentryRecipient = _recipient;
        reentryAmount = _amount;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.Revert) {
            revert("MaliciousERC20: forced revert");
        }
        if (mode == Mode.ReturnFalse) {
            // Don't actually move funds — pure protocol-compliance lie.
            return false;
        }
        if (mode == Mode.ReenterRecover) {
            // Re-enter into the account's recoverERC20 BEFORE completing
            // the transfer. The account contract is not reentrancy-guarded
            // — this proves whether that's a problem or not.
            target.recoverERC20(address(this), reentryRecipient, reentryAmount);
        }
        return super.transfer(to, amount);
    }
}
