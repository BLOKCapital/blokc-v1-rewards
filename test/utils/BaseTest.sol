// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";
import {RewardDistributor} from "src/contracts/RewardDistributor.sol";

import {MockBLOKC} from "test/mocks/MockBLOKC.sol";

import {Constants} from "test/utils/Constants.sol";
import {Events} from "test/utils/Events.sol";
import {Users} from "test/utils/Users.sol";

/// @notice Shared harness inherited by every test in the suite. Deploys
///         the mock token, the account implementation and the factory,
///         materialises the named user set, mints test funds and warps
///         to a stable pre-unlock baseline.
///
/// @dev    `setUp` does NOT create any contributor accounts. Tests that
///         need an account call `_createAccount(user)` themselves so
///         that creation, funding and the unlock-time boundary stay
///         under each test's control.
abstract contract BaseTest is Test, Events {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Named test actors. Populated in `setUp`.
    Users internal users;

    /// @notice Mock $BLOKC token (ERC20Votes-compatible).
    MockBLOKC internal blokc;

    /// @notice Singleton implementation that every clone delegatecalls into.
    BLOKCContributorAccount internal implementation;

    /// @notice Production-shaped factory bound to `blokc`, `implementation`
    ///         and `Constants.UNLOCK_TIMESTAMP`.
    BLOKCContributorFactory internal factory;

    /// @notice Reward distributor with AI proposer + 2-of-2 multisig.
    RewardDistributor internal distributor;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // 1. Pin time well before unlock so warps move forward only.
        vm.warp(Constants.START_TIMESTAMP);

        // 2. Build the labelled user set.
        users = Users({
            deployer: _user("deployer"),
            contributor: _user("contributor"),
            otherContributor: _user("otherContributor"),
            attacker: _user("attacker"),
            recipient: _user("recipient"),
            goodSamaritan: _user("goodSamaritan"),
            aiProposer: _user("aiProposer"),
            distributorOwner: _user("distributorOwner"),
            signer1: _user("signer1"),
            signer2: _user("signer2")
        });

        // 3. Deploy rails as the deployer for realistic msg.sender in traces.
        vm.startPrank(users.deployer);

        blokc = new MockBLOKC();
        vm.label(address(blokc), "MockBLOKC");

        implementation = new BLOKCContributorAccount();
        vm.label(address(implementation), "AccountImpl");

        factory = new BLOKCContributorFactory(address(blokc), address(implementation), Constants.UNLOCK_TIMESTAMP);
        vm.label(address(factory), "Factory");

        // 4. Deploy the reward distributor with 2-of-2 multisig.
        {
            address[] memory distSigners = new address[](2);
            distSigners[0] = users.signer1;
            distSigners[1] = users.signer2;
            distributor = new RewardDistributor(
                address(blokc),
                factory,
                users.aiProposer,
                users.distributorOwner,
                distSigners,
                2
            );
        }
        vm.label(address(distributor), "RewardDistributor");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint a fresh, labelled, ETH-funded EOA.
    function _user(string memory name) internal returns (address payable u) {
        u = payable(makeAddr(name));
        vm.deal(u, 100 ether);
    }

    /// @notice Deploy `contributor`'s account via the factory using the
    ///         caller-overload (i.e. contributor deploys it themselves).
    function _createAccount(address contributor) internal returns (BLOKCContributorAccount account) {
        vm.prank(contributor);
        account = BLOKCContributorAccount(factory.createContributorAccount());
    }

    /// @notice Mint $BLOKC directly into an account address.
    /// @dev    Uses the default fund amount from `Constants`.
    function _fundAccount(address account) internal {
        _fundAccount(account, Constants.DEFAULT_FUND_AMOUNT);
    }

    function _fundAccount(address account, uint256 amount) internal {
        blokc.mint(account, amount);
    }

    /// @notice Deploy `users.contributor`'s account and mint the default
    ///         $BLOKC fund into it. Convenience wrapper used by tests that
    ///         need a single funded account in one line.
    function _fundedAccount() internal returns (BLOKCContributorAccount a) {
        a = _createAccount(users.contributor);
        _fundAccount(address(a));
    }

    /// @notice Warp to exactly the unlock second (boundary tests).
    function _warpToUnlock() internal {
        vm.warp(Constants.AT_UNLOCK);
    }

    /// @notice Warp comfortably past the unlock second.
    function _warpPastUnlock() internal {
        vm.warp(Constants.POST_UNLOCK);
    }

    /// @notice Warp to one second before unlock (boundary tests).
    function _warpToJustBeforeUnlock() internal {
        vm.warp(Constants.PRE_UNLOCK);
    }

    /// @notice Fund the distributor with enough $BLOKC for multiple epochs.
    function _fundDistributor() internal {
        _fundDistributor(Constants.DISTRIBUTOR_FUND_AMOUNT);
    }

    function _fundDistributor(uint256 amount) internal {
        blokc.mint(address(distributor), amount);
    }

    /// @notice Create contributor accounts for a batch of synthetic addresses.
    /// @param count Number of contributors to create.
    /// @return contributors The array of contributor addresses.
    function _createContributors(uint256 count) internal returns (address[] memory contributors) {
        contributors = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            contributors[i] = address(uint160(0x1000 + i));
            vm.prank(contributors[i]);
            factory.createContributorAccount();
        }
    }
}
