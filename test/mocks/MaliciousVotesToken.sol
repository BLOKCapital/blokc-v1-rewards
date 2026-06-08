// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";

/// @notice ERC20Votes-shaped token whose `delegate` callback re-enters
///         `BLOKCContributorFactory.createContributorAccount` for a
///         configured contributor.
///
/// @dev    Why this exists:
///         `BLOKCContributorFactory._createContributorAccount` writes the
///         registry (`accounts.push`, `holdsAccount`, `accountOf`)
///         BEFORE calling `BLOKCContributorAccount.initialize`, which in
///         turn calls `IVotes(token).delegate(contributor)`. The dev
///         comment at `BLOKCContributorFactory.sol:189-193` claims this
///         ordering makes a reentry from `delegate` safe because the
///         second create call hits the idempotent short-circuit.
///
///         This mock lets a test prove that claim:
///           1. Factory deployed with this token as `_token`.
///           2. Factory.createContributorAccount(contributor) is called.
///           3. During initialize -> delegate(contributor), this token re-enters
///              factory.createContributorAccount().
///           4. Test asserts: same address returned, `accounts.length == 1`,
///              exactly one `ContributorAccountCreated` event.
///
///         Set `factory` and `reentryContributor` BEFORE the create call
///         that should trigger reentry.
contract MaliciousVotesToken is ERC20, ERC20Votes {
    BLOKCContributorFactory public factory;
    address public reentryContributor;
    bool public reentryArmed;

    /// @notice Captured outcome of the reentrant call, for assertions.
    address public reentryReturn;
    uint256 public reentryDepth;

    constructor() ERC20("MalVotes", "MVOTES") EIP712("MalVotes", "1") {}

    function arm(BLOKCContributorFactory _factory, address _reentryContributor) external {
        factory = _factory;
        reentryContributor = _reentryContributor;
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
    ///      external entry point used by `BLOKCContributorAccount.initialize`.
    function delegate(address delegatee) public override {
        // Carry out the real delegation first so the underlying state stays
        // consistent — the reentry is the "extra" behaviour layered on top.
        super.delegate(delegatee);

        if (reentryArmed && reentryDepth == 0) {
            reentryDepth = 1;
            reentryReturn = factory.createContributorAccount();
            // Disarm so deeper recursion doesn't loop indefinitely if the
            // short-circuit fails.
            reentryArmed = false;
        }
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
