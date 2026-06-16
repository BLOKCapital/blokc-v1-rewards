// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared timestamps and amounts used across the test suite.
/// @dev    Times are Unix seconds. Amounts assume 18-decimal $BLOKC.
library Constants {
    /// @notice Production unlock timestamp baked into the deployed factory:
    ///         1 May 2027 00:00:00 UTC. Verify with: date -u -d "1809734400 seconds"
    uint64 internal constant UNLOCK_TIMESTAMP = 1_809_734_400;

    /// @notice One second before unlock — boundary for "still locked" tests.
    uint64 internal constant PRE_UNLOCK = UNLOCK_TIMESTAMP - 1;

    /// @notice Exactly the unlock second — withdrawals must succeed here.
    uint64 internal constant AT_UNLOCK = UNLOCK_TIMESTAMP;

    /// @notice One day after unlock — "comfortably unlocked" baseline.
    uint64 internal constant POST_UNLOCK = UNLOCK_TIMESTAMP + 1 days;

    /// @notice Default test starting timestamp. One year before unlock so
    ///         tests can warp forward without underflow.
    uint64 internal constant START_TIMESTAMP = UNLOCK_TIMESTAMP - 365 days;

    /// @notice Default $BLOKC balance funded into a contributor account
    ///         by `BaseTest._fundAccount` when no amount is specified.
    uint256 internal constant DEFAULT_FUND_AMOUNT = 1_000_000e18;

    /// @notice Default $BLOKC amount minted to the BLOKCDistributor for
    ///         testing (100x a typical weekly distribution so tests never
    ///         hit balance shortages).
    uint256 internal constant DISTRIBUTOR_FUND_AMOUNT = 500_000e18;
}
