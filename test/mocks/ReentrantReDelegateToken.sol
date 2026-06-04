// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {BLOKCAmbassadorAccount} from "src/contracts/BLOKCAmbassadorAccount.sol";

/// @notice ERC20Votes-shaped token whose `delegate` callback re-enters
///         `BLOKCAmbassadorAccount.reDelegate` on a configured account.
///
/// @dev    Companion to {MaliciousVotesToken} (which re-enters the
///         *factory*). This one targets the *account*'s `reDelegate`:
///         `reDelegate` calls `_delegate → IVotes(token).delegate`, so a
///         malicious token can attempt to re-enter `reDelegate` from that
///         callback. The test proves the `onlyAmbassador` gate blocks it —
///         the reentry's `msg.sender` is this token, not the ambassador, so
///         the whole call reverts and delegation is left untouched.
///
///         Arm AFTER the account is created: `initialize` already fires a
///         `delegate`, and arming first would trigger reentry during setup.
contract ReentrantReDelegateToken is ERC20, ERC20Votes {
    BLOKCAmbassadorAccount public targetAccount;
    address public reentryDelegatee;
    bool public reentryArmed;

    constructor() ERC20("ReVotes", "RVOTES") EIP712("ReVotes", "1") {}

    function arm(BLOKCAmbassadorAccount _account, address _delegatee) external {
        targetAccount = _account;
        reentryDelegatee = _delegatee;
        reentryArmed = true;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Override `delegate` (not `_delegate`) to intercept the external
    ///      entry point that {BLOKCAmbassadorAccount} calls.
    function delegate(address delegatee) public override {
        super.delegate(delegatee);

        if (reentryArmed) {
            // One-shot: disarm before re-entering so a failure can't loop.
            reentryArmed = false;
            targetAccount.reDelegate(reentryDelegatee);
        }
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
