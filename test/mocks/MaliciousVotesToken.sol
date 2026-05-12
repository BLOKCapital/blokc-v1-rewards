// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {BLOKCAmbassadorFactory} from "src/contracts/factory/BLOKCAmbassadorFactory.sol";

/// @notice ERC20Votes-shaped token whose `delegate` callback re-enters
///         `BLOKCAmbassadorFactory.createAmbassadorAccount` for a
///         configured ambassador.
///
/// @dev    Why this exists:
///         `BLOKCAmbassadorFactory._createAmbassadorAccount` writes the
///         registry (`accounts.push`, `holdsAccount`, `accountOf`)
///         BEFORE calling `BLOKCAmbassadorAccount.initialize`, which in
///         turn calls `IVotes(token).delegate(ambassador)`. The dev
///         comment at `BLOKCAmbassadorFactory.sol:189-193` claims this
///         ordering makes a reentry from `delegate` safe because the
///         second create call hits the idempotent short-circuit.
///
///         This mock lets a test prove that claim:
///           1. Factory deployed with this token as `_token`.
///           2. Factory.createAmbassadorAccount(amb) is called.
///           3. During initialize → delegate(amb), this token re-enters
///              factory.createAmbassadorAccount(amb).
///           4. Test asserts: same address returned, `accounts.length == 1`,
///              exactly one `AmbassadorAccountCreated` event.
///
///         Set `factory` and `reentryAmbassador` BEFORE the create call
///         that should trigger reentry.
contract MaliciousVotesToken is ERC20, ERC20Votes {
    BLOKCAmbassadorFactory public factory;
    address public reentryAmbassador;
    bool public reentryArmed;

    /// @notice Captured outcome of the reentrant call, for assertions.
    address public reentryReturn;
    uint256 public reentryDepth;

    constructor() ERC20("MalVotes", "MVOTES") EIP712("MalVotes", "1") {}

    function arm(BLOKCAmbassadorFactory _factory, address _reentryAmbassador) external {
        factory = _factory;
        reentryAmbassador = _reentryAmbassador;
        reentryArmed = true;
        reentryDepth = 0;
        reentryReturn = address(0);
    }

    function disarm() external {
        reentryArmed = false;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Override `delegate` (not `_delegate`) so we intercept the
    ///      external entry point used by `BLOKCAmbassadorAccount.initialize`.
    function delegate(address delegatee) public override {
        // Carry out the real delegation first so the underlying state stays
        // consistent — the reentry is the "extra" behaviour layered on top.
        super.delegate(delegatee);

        if (reentryArmed && reentryDepth == 0) {
            reentryDepth = 1;
            reentryReturn = factory.createAmbassadorAccount(reentryAmbassador);
            // Disarm so deeper recursion doesn't loop indefinitely if the
            // short-circuit fails.
            reentryArmed = false;
        }
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
