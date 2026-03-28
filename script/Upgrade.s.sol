// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {NousOracle} from "../src/NousOracle.sol";

/// @title UpgradeScript
/// @notice Upgrades the NousOracle UUPS proxy to a new implementation and
///         configures dispute resolution parameters.
///
/// Required env vars:
///   PRIVATE_KEY          — deployer (must be proxy owner)
///   PROXY_ADDRESS        — existing ERC1967 proxy
///
/// Optional env vars (dispute config, applied post-upgrade):
///   DISPUTE_WINDOW              — seconds (default: 3600 = 1 hour)
///   DISPUTE_BOND_MULTIPLIER     — e.g. 150 = 1.5x (default: 150)
///   DAO_ADDRESS                 — multisig / governor (default: skip)
///   DAO_ESCALATION_BOND_TOKEN   — Taiko ERC-20 address (default: skip)
///   DAO_ESCALATION_BOND         — wei amount (default: skip)
///   DAO_RESOLUTION_WINDOW       — seconds (default: 604800 = 7 days)
///   MIN_STAKE_AMOUNT            — wei (default: 0.5 ether)
///   SLASH_PERCENTAGE            — basis points (default: 5000 = 50%)
///   WITHDRAWAL_COOLDOWN         — seconds (default: 86400 = 1 day)
///   DISPUTE_BOND_AMOUNT         — wei (default: 0.2 ether)
contract UpgradeScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new implementation
        NousOracle newImpl = new NousOracle();
        console.log("New implementation deployed at:", address(newImpl));

        // 2. Upgrade proxy (owner-only, UUPS)
        NousOracle proxy = NousOracle(proxyAddress);
        proxy.upgradeToAndCall(address(newImpl), "");
        console.log("Proxy upgraded:", proxyAddress);

        // 3. Configure dispute parameters
        uint256 disputeWindow = vm.envOr("DISPUTE_WINDOW", uint256(1 hours));
        uint256 disputeBondMultiplier = vm.envOr("DISPUTE_BOND_MULTIPLIER", uint256(150));

        proxy.setDisputeWindow(disputeWindow);
        console.log("Dispute window set:", disputeWindow);

        proxy.setDisputeBondMultiplier(disputeBondMultiplier);
        console.log("Dispute bond multiplier set:", disputeBondMultiplier);

        // 4. Configure DAO escalation (optional — only if DAO_ADDRESS is set)
        address daoAddress = vm.envOr("DAO_ADDRESS", address(0));
        if (daoAddress != address(0)) {
            proxy.setDaoAddress(daoAddress);
            console.log("DAO address set:", daoAddress);

            address bondToken = vm.envAddress("DAO_ESCALATION_BOND_TOKEN");
            proxy.setDaoEscalationBondToken(bondToken);
            console.log("DAO escalation bond token set:", bondToken);

            uint256 escalationBond = vm.envUint("DAO_ESCALATION_BOND");
            proxy.setDaoEscalationBond(escalationBond);
            console.log("DAO escalation bond set:", escalationBond);

            uint256 resolutionWindow = vm.envOr("DAO_RESOLUTION_WINDOW", uint256(7 days));
            proxy.setDaoResolutionWindow(resolutionWindow);
            console.log("DAO resolution window set:", resolutionWindow);
        } else {
            console.log("DAO_ADDRESS not set - skipping DAO escalation config");
        }

        // 5. Configure staking parameters
        uint256 minStake = vm.envOr("MIN_STAKE_AMOUNT", uint256(0.5 ether));
        uint256 slashPct = vm.envOr("SLASH_PERCENTAGE", uint256(5000));
        uint256 withdrawCooldown = vm.envOr("WITHDRAWAL_COOLDOWN", uint256(1 days));
        uint256 flatDisputeBond = vm.envOr("DISPUTE_BOND_AMOUNT", uint256(0.2 ether));

        address stakeTokenAddr = vm.envOr("STAKE_TOKEN", address(0));
        if (stakeTokenAddr != address(0)) {
            proxy.setStakeToken(stakeTokenAddr);
            console.log("Stake token set:", stakeTokenAddr);
        }

        proxy.setMinStakeAmount(minStake);
        console.log("Min stake amount set:", minStake);

        proxy.setSlashPercentage(slashPct);
        console.log("Slash percentage set:", slashPct);

        proxy.setWithdrawalCooldown(withdrawCooldown);
        console.log("Withdrawal cooldown set:", withdrawCooldown);

        proxy.setDisputeBondAmount(flatDisputeBond);
        console.log("Dispute bond amount set:", flatDisputeBond);

        vm.stopBroadcast();
    }
}
