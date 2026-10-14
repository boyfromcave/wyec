// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {WrappedYcash} from "../contracts/WrappedYcash.sol";
import {IWrappedYcash, IWyecBridgeConsumed, WyecBridge} from "../contracts/WyecBridge.sol";

/// Deploys wYEC in the order of docs/wyec-contract-design.md §8: the bridge first, constructed
/// with the token address predicted from the deployer's next nonce, then the token in the very
/// next transaction from the same deployer. The prediction is asserted before and after.
///
/// Environment:
///   GUARDIANS          comma-separated guardian addresses (required)
///   THRESHOLD          k of the threshold mint and the admin acts (required; >= 2 on mainnet)
///   CHALLENGE_WINDOW   optimistic-mint challenge window in seconds (required, > 0; >= 2 hours on
///                      mainnet)
///   MINT_CAP           mint rate limit in wYEC base units per CAP_WINDOW (default 0 = no limit;
///                      not on mainnet, where it is required)
///   CAP_WINDOW         rate-limit window in seconds (default 0; > 0 when MINT_CAP > 0)
///   MAX_OPEN_PROPOSALS most proposals one proposer may have open (default 0 = no limit;
///                      not on mainnet, where it is required)
///   DEPLOYMENT_FILE    output path (default deployments/<chainid>.json)
///   OLD_BRIDGE         a successor deployment (design §4.6): the bridge being succeeded. The new
///                      bridge drives OLD_BRIDGE's token (no new token is deployed), and the
///                      script prints the SetBridge act the guardians sign on OLD_BRIDGE next.
///   PREDECESSOR        what the successor reads `isConsumed` from (default OLD_BRIDGE; for a
///                      generation-0 OLD_BRIDGE, a ConsumedView over it)
///
/// Output: {chainId, bridge, token, deployBlock, guardians, threshold, challengeWindow, mintCap,
/// capWindow}. deployBlock is the first block the deployment can be in (head + 1 at script
/// time): exact on an automining anvil, a safe lower bound for a log scanner elsewhere.
///
///   forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $KEY
contract Deploy is Script {
    struct Result {
        address bridge;
        address token;
        uint256 deployBlock;
    }

    struct Config {
        address[] guardians;
        uint256 threshold;
        uint256 challengeWindow;
        uint256 mintCap;
        uint256 capWindow;
        uint256 maxOpenProposals;
        string file;
        /// A successor deployment: the bridge succeeded (address(0) for a first deployment).
        address oldBridge;
        /// The successor's `predecessor` (default `oldBridge`).
        address predecessor;
    }

    function run() external returns (Result memory) {
        Config memory c;
        c.guardians = vm.envAddress("GUARDIANS", ",");
        c.threshold = vm.envUint("THRESHOLD");
        c.challengeWindow = vm.envUint("CHALLENGE_WINDOW");
        c.mintCap = vm.envOr("MINT_CAP", uint256(0));
        c.capWindow = vm.envOr("CAP_WINDOW", uint256(0));
        c.maxOpenProposals = vm.envOr("MAX_OPEN_PROPOSALS", uint256(0));
        c.oldBridge = vm.envOr("OLD_BRIDGE", address(0));
        c.predecessor = vm.envOr("PREDECESSOR", c.oldBridge);
        c.file = vm.envOr(
            "DEPLOYMENT_FILE",
            string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json")
        );
        return deploy(c);
    }

    function deploy(Config memory c) public returns (Result memory r) {
        require(
            c.threshold > 0 && c.threshold <= c.guardians.length && c.threshold <= type(uint8).max,
            "bad THRESHOLD"
        );
        // With k = 1 one key mints immediately through `mint`, bypassing the optimistic window
        // (design §4.5): never on mainnet.
        require(block.chainid != 1 || c.threshold >= 2, "THRESHOLD must be >= 2 on mainnet");
        require(c.challengeWindow > 0 && c.challengeWindow <= type(uint64).max, "bad CHALLENGE_WINDOW");
        // The constructor enforces the same two floors (design §4.5.3); checked here first so the
        // script fails before broadcasting, with a message naming the variable.
        require(
            block.chainid != 1 || c.challengeWindow >= 2 hours,
            "CHALLENGE_WINDOW must be >= 2 hours on mainnet"
        );
        require(block.chainid != 1 || c.mintCap > 0, "MINT_CAP is required on mainnet");
        require(block.chainid != 1 || c.maxOpenProposals > 0, "MAX_OPEN_PROPOSALS is required on mainnet");
        require(c.mintCap == 0 || c.capWindow > 0, "CAP_WINDOW must be > 0 when MINT_CAP > 0");

        if (c.oldBridge != address(0)) return deploySuccessor(c);
        require(c.predecessor == address(0), "PREDECESSOR without OLD_BRIDGE");
        r.deployBlock = block.number + 1;
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);

        // casting is safe: both bounds are required above.
        // forge-lint: disable-next-item(unsafe-typecast)
        WyecBridge bridge = new WyecBridge(
            IWrappedYcash(predicted),
            c.guardians,
            uint8(c.threshold),
            uint64(c.challengeWindow),
            c.mintCap,
            c.capWindow,
            c.maxOpenProposals,
            IWyecBridgeConsumed(address(0))
        );
        WrappedYcash token = new WrappedYcash(address(bridge));
        vm.stopBroadcast();

        require(address(token) == predicted, "token address prediction failed");
        require(
            address(bridge.token()) == address(token) && token.bridge() == address(bridge), "pair mismatch"
        );
        r.bridge = address(bridge);
        r.token = address(token);
        write(c, r);
    }

    /// A successor (design §4.6): a new bridge over OLD_BRIDGE's token, reading consumed lockIds
    /// from PREDECESSOR. The token is not touched here: the hand-off is OLD_BRIDGE's threshold-
    /// signed `setBridge(newBridge)`, printed for the guardians to sign after re-reading the new
    /// bridge (guardians, threshold, window, cap, predecessor).
    function deploySuccessor(Config memory c) internal returns (Result memory r) {
        WrappedYcash token = WrappedYcash(address(WyecBridge(c.oldBridge).token()));
        require(token.bridge() == c.oldBridge, "OLD_BRIDGE is not the token's current bridge");
        require(c.predecessor != address(0), "a successor needs a PREDECESSOR");
        r.deployBlock = block.number + 1;
        vm.startBroadcast();
        // casting is safe: both bounds are required in deploy().
        // forge-lint: disable-next-item(unsafe-typecast)
        WyecBridge bridge = new WyecBridge(
            IWrappedYcash(address(token)),
            c.guardians,
            uint8(c.threshold),
            uint64(c.challengeWindow),
            c.mintCap,
            c.capWindow,
            c.maxOpenProposals,
            IWyecBridgeConsumed(c.predecessor)
        );
        vm.stopBroadcast();
        require(address(bridge.predecessor()) == c.predecessor, "predecessor mismatch");
        r.bridge = address(bridge);
        r.token = address(token);
        write(c, r);
        console.log("next: guardians sign on OLD_BRIDGE", c.oldBridge);
        console.log("  SetBridge(address newBridge,uint256 adminNonce) newBridge", r.bridge);
        console.log("  adminNonce", WyecBridge(c.oldBridge).adminNonce());
    }

    function write(Config memory c, Result memory r) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "bridge", r.bridge);
        vm.serializeAddress(o, "token", r.token);
        vm.serializeUint(o, "deployBlock", r.deployBlock);
        vm.serializeAddress(o, "guardians", c.guardians);
        vm.serializeUint(o, "threshold", c.threshold);
        vm.serializeUint(o, "challengeWindow", c.challengeWindow);
        vm.serializeUint(o, "mintCap", c.mintCap);
        vm.serializeUint(o, "maxOpenProposals", c.maxOpenProposals);
        vm.serializeAddress(o, "predecessor", c.predecessor);
        string memory json = vm.serializeUint(o, "capWindow", c.capWindow);
        vm.writeJson(json, c.file);

        console.log("bridge     ", r.bridge);
        console.log("token      ", r.token);
        console.log("deployBlock", r.deployBlock);
        console.log("written    ", c.file);
    }
}
