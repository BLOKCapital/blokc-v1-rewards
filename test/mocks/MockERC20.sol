// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC20 used as the "foreign token" in `recoverERC20`
///         happy-path tests and in the account handler. Distinct from
///         `MockBLOKC` so tests never accidentally conflate the locked
///         asset with a recoverable foreign token.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
