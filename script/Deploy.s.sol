// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NousOracle} from "../src/NousOracle.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        uint256 revealDuration = vm.envOr("REVEAL_DURATION", uint256(1 hours));

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        NousOracle implementation = new NousOracle();
        console.log("Implementation deployed at:", address(implementation));

        // Deploy proxy
        bytes memory initData = abi.encodeCall(NousOracle.initialize, (owner, revealDuration));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed at:", address(proxy));

        vm.stopBroadcast();
    }
}
