pragma solidity ^0.8.24;

/*###############################################################################

    @title BLOKCAmbassador Factory (clone-safe)
    @author BLOK Capital DAO
    @notice Permissionless factory that deploys BLOKCAmbassadorAccount instances
 *         as deterministic EIP-1167 minimal proxy clones. Each ambassador's
 *         account address is derived from their wallet address as salt, so:
 *
 *           - account creation is idempotent: same ambassador → same address
 *           - the account address is knowable in advance, before deployment
 *           - the team can pre-fund an ambassador before they deploy
 *
 *         Unlike BLOKCVestingFactory, this factory has no privileged owner
 *         and no admin functions. Anyone can call createAccount() to deploy
 *         their own account; nobody can deploy another address's account.
 *
 *         The unlock timestamp is set once at factory deployment and applies
 *         uniformly to every account this factory creates. Deploying a new
 *         factory is the only way to change the unlock date — and existing
 *         accounts continue to enforce the date they were initialized with.

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

// import (Clones) from "openzeppelin-contracts/contracts/proxy/Clones.sol";
// import (ERC20) from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

// import {BLOKCAmbassadorAccount} from "../account/BLOKCAmbassadorAccount.sol";

// contract BLOKCAmbassadorFactory {
//     //this factory is minimal proxy clone factory for BLOKCAmbassadorAccount
//     //the only sole purpose of this factory is to deploy simple ambassador accounts
//     //using the special proxy to save gas on deployment and nothing more

// }
