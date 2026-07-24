// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";
import {BLOKCDistributor} from "src/contracts/BLOKCDistributor.sol";

/// @title Deploy
/// @notice Deploys the full BLOKC rewards protocol. Signers are added later
///         through DAO governance votes, so the distributor starts with an
///         empty signer array.
///
///         Required env vars:
///           BLOKC_TOKEN       - canonical $BLOKC ERC20Votes token address
///           AI_PROPOSER       - AI agent's EOA wallet
///           DISTRIBUTOR_OWNER - DAO multisig / Aragon agent address
///
///         The unlock timestamp is hardcoded: 1 May 2027 00:00:00 UTC.
///         Verify with: date -u -d 1809734400
contract Deploy is Script {
    uint64 internal constant UNLOCK_TIMESTAMP = 1_809_734_400;

    function run() external {
        address blokcToken = vm.envAddress("BLOKC_TOKEN");
        address aiProposer = vm.envAddress("AI_PROPOSER");
        address distributorOwner = vm.envAddress("DISTRIBUTOR_OWNER");

        vm.startBroadcast();

        // 1. Deploy the account implementation. Its constructor calls
        //    _disableInitializers() so the implementation itself can never
        //    be initialized directly - only EIP-1167 clones can.
        BLOKCContributorAccount implementation = new BLOKCContributorAccount();
        console.log("BLOKCContributorAccount implementation:", address(implementation));

        // 2. Sanity-check: the implementation rejects direct initialization.
        try implementation.initialize(address(0x1), blokcToken, UNLOCK_TIMESTAMP) {
            revert("FAIL: implementation accepted direct initialize()");
        } catch {
            console.log("Implementation locked: direct initialize() reverted (OK)");
        }

        // 3. Deploy the factory. Bound to the token, implementation, and
        //    unlock date. All three are immutable.
        BLOKCContributorFactory factory =
            new BLOKCContributorFactory(blokcToken, address(implementation), UNLOCK_TIMESTAMP);
        console.log("BLOKCContributorFactory:", address(factory));
        console.log("  _token:", blokcToken);
        console.log("  _implementation:", address(implementation));
        console.log("  _unlockTimestamp:", UNLOCK_TIMESTAMP);

        // 4. Deploy the distributor with an empty signer array. Signers are
        //    added through DAO governance votes after deployment. No
        //    distribution can be proposed until at least 2 signers exist.
        address[] memory signers = new address[](0);
        BLOKCDistributor distributor =
            new BLOKCDistributor(blokcToken, factory, aiProposer, distributorOwner, signers);
        console.log("BLOKCDistributor:", address(distributor));
        console.log("  _token:", blokcToken);
        console.log("  _factory:", address(factory));
        console.log("  _proposer:", aiProposer);
        console.log("  _owner:", distributorOwner);
        console.log("  _signers: [] (empty - add via DAO votes)");

        vm.stopBroadcast();
        console.log("Deploy complete.");
    }
}
