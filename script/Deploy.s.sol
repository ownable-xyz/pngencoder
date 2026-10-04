// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PNGEncoder} from "../src/PNGEncoder.sol";

/// @title  PNGEncoder deployment script
/// @notice Deploys {PNGEncoder}. The encoder links the {Deflate} library.
///         `forge` deploys and links that library automatically during the
///         broadcast. The broadcast sends two transactions: `Deflate`, then
///         `PNGEncoder`.
/// @dev    The interactive `./deploy.sh` script runs this script. That script
///         does the network selection, the Ledger account selection, the
///         dry-run simulation, the balance and chain-id checks, the
///         confirmation prompts and the checks after the deploy.
///         You can also run this script directly, for example:
///
///           # simulate only (no chain state touched)
///           forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --sender "$ADDR"
///
///           # broadcast, signing with a Ledger
///           forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" \
///               --ledger --hd-paths "m/44'/60'/0'/0/0" --sender "$ADDR" --broadcast
///
///         `--sender` must be the address that signs. Then the nonce and the
///         authorization of the simulation agree with the broadcast.
contract Deploy is Script {
    function run() external returns (PNGEncoder enc) {
        vm.startBroadcast();
        enc = new PNGEncoder();
        vm.stopBroadcast();

        // This check shows in the run log. A newly deployed encoder must have
        // code.
        require(address(enc).code.length > 0, "PNGEncoder has no code");
        console2.log("PNGEncoder deployed at:", address(enc));
    }
}
