// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SuperTorchArena} from "../src/SuperTorchArena.sol";

/// forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_KEY
contract Deploy is Script {
    function run() external {
        address owner = vm.envAddress("OWNER"); // your multisig
        address settler = vm.envAddress("SETTLER"); // verification server wallet
        address treasury = vm.envAddress("TREASURY"); // receives the protocol share
        address burnWallet = vm.envAddress("BURN_WALLET"); // burn worker wallet
        uint256 entryFee = vm.envUint("ENTRY_FEE_WEI"); // e.g. 1000000000000000 = 0.001 ETH
        uint256 resetOffset = vm.envOr("RESET_OFFSET", uint256(0)); // seconds after 00:00 UTC
        // split in basis points (100 = 1%): 1st, 2nd, 3rd, burn. Protocol gets the rest.
        uint16[3] memory places = [uint16(vm.envOr("FIRST_BPS", uint256(4000))), uint16(vm.envOr("SECOND_BPS", uint256(2000))), uint16(vm.envOr("THIRD_BPS", uint256(1000)))];
        uint16 burnBps = uint16(vm.envOr("BURN_BPS", uint256(1500)));

        vm.startBroadcast();
        SuperTorchArena arena = new SuperTorchArena(resetOffset, entryFee, owner, settler, treasury, burnWallet, places, burnBps);
        vm.stopBroadcast();

        console.log("SuperTorchArena deployed at", address(arena));
        console.log("Deploy block", block.number);
    }
}
