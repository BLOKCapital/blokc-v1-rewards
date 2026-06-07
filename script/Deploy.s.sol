// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {BLOKCContributorAccount} from "src/contracts/BLOKCContributorAccount.sol";
import {BLOKCContributorFactory} from "src/contracts/factory/BLOKCContributorFactory.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title Deploy
/// @notice
///         Pre-requisites:
///           - BLOKC_TOKEN environment variable set to the canonical $BLOKC
///             ERC20Votes token address.
///           - DEPLOYER_KEY or --ledger/--trezor for the deployer account.
///           - Etherscan API key in ETHERSCAN_API_KEY env var for verify.
///
///         The unlock timestamp is hardcoded: 1 May 2027 00:00:00 UTC.
///         Verify with: date -u -d 1809734400
contract Deploy is Script {
    /// @notice Production unlock timestamp (1 May 2027 00:00:00 UTC).
    uint64 internal constant UNLOCK_TIMESTAMP = 1_809_734_400;

    function run() external {
        address blokcToken = vm.envAddress("BLOKC_TOKEN");

        vm.startBroadcast();

        // 1. Deploy the account implementation. Its constructor calls
        //    _disableInitializers()
        BLOKCContributorAccount implementation = new BLOKCContributorAccount();
        console.log("BLOKCContributorAccount implementation:", address(implementation));

        // 2. Sanity-check: the implementation rejects direct initialization.
        try implementation.initialize(address(0x1), blokcToken, UNLOCK_TIMESTAMP) {
            revert("FAIL: implementation accepted direct initialize()");
        } catch {
            console.log("Implementation locked: direct initialize() reverted (OK)");
        }

        // 3. Deploy the factory. Bound to this token + implementation +
        //    unlock date.
        BLOKCContributorFactory factory =
            new BLOKCContributorFactory(blokcToken, address(implementation), UNLOCK_TIMESTAMP);
        console.log("BLOKCContributorFactory deployed:", address(factory));

        // 4. Log constructor args for Etherscan verification.
        console.log("---");
        console.log("Constructor args for BLOKCContributorFactory:");
        console.log("  _token:", blokcToken);
        console.log("  _implementation:", address(implementation));
        console.log("  _unlockTimestamp:", UNLOCK_TIMESTAMP);
        console.log("---");

        // 5. Predict the first contributor address as a smoke test.
        //    This address can receive $BLOKC immediately, even before the
        //    account is deployed, the clone inherits whatever sits at its
        //    deterministic CREATE2 address.
        address firstContributor = vm.envOr("FIRST_CONTRIBUTOR", address(0x1));
        address predicted = factory.predictContributorAccount(firstContributor);
        console.log("Predicted account for", firstContributor, ":", predicted);

        vm.stopBroadcast();
    }
}
