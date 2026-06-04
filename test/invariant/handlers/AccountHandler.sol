// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {BLOKCAmbassadorAccount} from "src/contracts/BLOKCAmbassadorAccount.sol";

import {MockBLOKC} from "test/mocks/MockBLOKC.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @notice Bounded handler that drives a single `BLOKCAmbassadorAccount`
///         through random combinations of its public actions, for use by
///         `AccountInvariant.t.sol`. Without a handler, the invariant
///         fuzzer wastes most runs on reverts (wrong sender, zero
///         amounts, etc).
///
/// @dev    The handler always pranks as the bound `ambassador`, so
///         `onlyAmbassador` never trips. Time travel and funding are
///         exposed as bounded actions so invariant runs can cover
///         lifecycle states without the engine spending its budget on
///         arithmetic that would otherwise revert.
///
///         Ghost variables track flows the invariants rely on:
///           - `g_totalFunded`     — total $BLOKC ever minted into the account
///           - `g_totalWithdrawn`  — total $BLOKC ever sent out via withdraw paths
///           - `g_callCounts`      — selector-keyed call counts, useful to
///                                   verify the fuzzer actually exercised
///                                   each path during a run
contract AccountHandler is CommonBase, StdCheats, StdUtils {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    BLOKCAmbassadorAccount public account;
    MockBLOKC public blokc;
    MockERC20 public foreignToken;

    address public ambassador;
    address[] public delegatees;

    // ghost vars
    uint256 public g_totalFunded;
    uint256 public g_totalWithdrawn;
    mapping(bytes32 => uint256) public g_callCounts;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        BLOKCAmbassadorAccount _account,
        MockBLOKC _blokc,
        MockERC20 _foreignToken,
        address _ambassador,
        address[] memory _delegatees
    ) {
        account = _account;
        blokc = _blokc;
        foreignToken = _foreignToken;
        ambassador = _ambassador;
        delegatees = _delegatees;
    }

    /*//////////////////////////////////////////////////////////////
                              HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint a bounded amount of $BLOKC into the account, simulating
    ///         ongoing rewards funding.
    function fund(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        blokc.mint(address(account), amount);
        g_totalFunded += amount;
        g_callCounts["fund"]++;
    }

    /// @notice Mint bounded foreign-token amount into the account so
    ///         `recoverERC20` has something to grab.
    function fundForeign(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        foreignToken.mint(address(account), amount);
        g_callCounts["fundForeign"]++;
    }

    /// @notice Try to withdraw a bounded amount. The fuzzer chooses the
    ///         amount; the handler caps it at the current balance to
    ///         avoid `InsufficientBalance` reverts dominating the run.
    function withdraw(uint256 amount, address to) external {
        uint256 bal = blokc.balanceOf(address(account));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        // Redirect zero and self-recipient: a withdrawal to the account
        // itself is a valid no-op that leaves the balance unchanged, which
        // would break the conservation ghost (`g_totalWithdrawn` counts it
        // as sent out though nothing left). Send to the ambassador instead.
        if (to == address(0) || to == address(account)) to = ambassador;
        if (block.timestamp < account.unlockTimestamp()) return;

        vm.prank(ambassador);
        account.withdraw(to, amount);

        g_totalWithdrawn += amount;
        g_callCounts["withdraw"]++;
    }

    /// @notice Try to sweep the entire balance. Same gating as `withdraw`.
    function withdrawAll() external {
        uint256 bal = blokc.balanceOf(address(account));
        if (bal == 0) return;
        if (block.timestamp < account.unlockTimestamp()) return;

        vm.prank(ambassador);
        account.withdrawTokensAll();

        g_totalWithdrawn += bal;
        g_callCounts["withdrawAll"]++;
    }

    /// @notice Recover a bounded amount of the foreign token.
    function recoverForeign(uint256 amount, address to) external {
        uint256 bal = foreignToken.balanceOf(address(account));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        if (to == address(0)) to = ambassador;

        vm.prank(ambassador);
        account.recoverERC20(address(foreignToken), to, amount);

        g_callCounts["recoverForeign"]++;
    }

    /// @notice Re-delegate to one of the pre-selected delegatees.
    function reDelegate(uint256 idx) external {
        if (delegatees.length == 0) return;
        address to = delegatees[idx % delegatees.length];

        vm.prank(ambassador);
        account.reDelegate(to);

        g_callCounts["reDelegate"]++;
    }

    /// @notice Bounded forward time travel. Capped at 90 days: small
    ///         enough that no single jump skips the 365-day pre-unlock
    ///         window from the start state, but large enough that a run
    ///         actually crosses into the unlocked region — otherwise
    ///         {invariant_account_noWithdrawalBeforeUnlock} is trivially
    ///         satisfied because unlock is never reached.
    function skipTime(uint256 secs) external {
        secs = bound(secs, 1, 90 days);
        vm.warp(block.timestamp + secs);
        g_callCounts["skipTime"]++;
    }
}
