// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @notice ERC20Votes-compatible mock of $BLOKC for the test suite.
/// @dev    The production account contract calls
///         `IVotes(token).delegate(ambassador)` inside `initialize`, so a
///         plain ERC20 mock would revert with no-such-function. This mock
///         inherits the OZ `ERC20Votes` extension which already wires
///         `_update` to keep checkpoints — no override needed.
///
///         `mint` is permissionless on purpose; tests mint freely into
///         arbitrary addresses (including ambassador account addresses,
///         to simulate funding from the DAO treasury).
contract MockBLOKC is ERC20, ERC20Votes {
    constructor() ERC20("Mock BLOKC", "MBLOKC") EIP712("Mock BLOKC", "1") {}

    /// @notice Permissionless mint, for tests only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Permissionless burn, for tests only.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /// @dev Required override — both ERC20 and ERC20Votes declare `_update`.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
