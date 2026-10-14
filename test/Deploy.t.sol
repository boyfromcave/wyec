// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {WrappedYcash} from "../contracts/WrappedYcash.sol";
import {WyecBridge} from "../contracts/WyecBridge.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// script/Deploy.s.sol in-process: predicted-address deployment and the deployment file.
contract DeployScriptTest is Test {
    using stdJson for string;

    // Configs are passed in, not through the environment: forge runs tests in parallel and
    // environment variables are process-wide.
    function config(string memory name) internal view returns (Deploy.Config memory c) {
        c.guardians = new address[](3);
        c.guardians[0] = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        c.guardians[1] = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
        c.guardians[2] = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
        c.threshold = 2;
        c.challengeWindow = 3600;
        c.mintCap = 1000e8;
        c.capWindow = 1 days;
        c.maxOpenProposals = 8;
        c.file = string.concat(vm.projectRoot(), "/deployments/.test-", name, ".json");
    }

    function test_Deploy_PairAndFile() public {
        Deploy.Config memory c = config("pair");
        string memory file = c.file;
        Deploy.Result memory r = new Deploy().deploy(c);
        WyecBridge b = WyecBridge(r.bridge);
        assertEq(address(b.token()), r.token);
        assertEq(WrappedYcash(r.token).bridge(), r.bridge);
        assertEq(b.threshold(), 2);
        assertEq(b.guardianCount(), 3);
        assertEq(b.challengeWindow(), 3600);
        assertEq(b.mintCap(), 1000e8);
        assertEq(b.capWindow(), 1 days);
        assertEq(b.maxOpenProposals(), 8);

        string memory j = vm.readFile(file);
        vm.removeFile(file);
        assertEq(j.readUint(".chainId"), block.chainid);
        assertEq(j.readAddress(".bridge"), r.bridge);
        assertEq(j.readAddress(".token"), r.token);
        assertEq(j.readUint(".deployBlock"), block.number + 1);
        assertEq(j.readUint(".threshold"), 2);
        assertEq(j.readUint(".challengeWindow"), 3600);
        assertEq(j.readUint(".mintCap"), 1000e8);
        assertEq(j.readUint(".capWindow"), 1 days);
        assertEq(j.readUint(".maxOpenProposals"), 8);
        address[] memory g = j.readAddressArray(".guardians");
        assertEq(g.length, 3);
        assertEq(g[2], 0x90F79bf6EB2c4f870365E785982E1f101E93b906);
    }

    /// threshold = 1 lets one key bypass the optimistic window: refused on mainnet only.
    function test_Deploy_MainnetNeedsThresholdTwo() public {
        Deploy.Config memory c = config("mainnet");
        c.threshold = 1;
        vm.chainId(1);
        Deploy d = new Deploy();
        vm.expectRevert(bytes("THRESHOLD must be >= 2 on mainnet"));
        d.deploy(c);

        vm.chainId(11155111);
        string memory file = c.file;
        Deploy.Result memory r = new Deploy().deploy(c);
        assertEq(WyecBridge(r.bridge).threshold(), 1);
        vm.removeFile(file);
    }

    /// The script refuses the constructor's other two mainnet floors before broadcasting, naming
    /// the variable; a config meeting all three deploys on chain id 1.
    function test_Deploy_MainnetWindowAndCapFloors() public {
        Deploy d = new Deploy();
        vm.chainId(1);
        Deploy.Config memory c = config("mainnet-floors");
        c.challengeWindow = 2 hours - 1;
        vm.expectRevert(bytes("CHALLENGE_WINDOW must be >= 2 hours on mainnet"));
        d.deploy(c);

        c = config("mainnet-floors");
        c.challengeWindow = 2 hours;
        c.mintCap = 0;
        c.capWindow = 0;
        vm.expectRevert(bytes("MINT_CAP is required on mainnet"));
        d.deploy(c);

        c = config("mainnet-floors");
        c.challengeWindow = 2 hours;
        c.maxOpenProposals = 0;
        vm.expectRevert(bytes("MAX_OPEN_PROPOSALS is required on mainnet"));
        d.deploy(c);

        c = config("mainnet-floors");
        c.challengeWindow = 2 hours;
        string memory file = c.file;
        Deploy.Result memory r = d.deploy(c);
        assertEq(WyecBridge(r.bridge).challengeWindow(), 2 hours);
        vm.removeFile(file);
    }

    /// A successor deployment (design §4.6): a new bridge over the old one's token, reading the
    /// old bridge's consumed lockIds; no new token; the file records the predecessor.
    function test_Deploy_Successor() public {
        Deploy d = new Deploy();
        Deploy.Config memory c = config("first");
        string memory f1 = c.file;
        Deploy.Result memory r = d.deploy(c);
        vm.removeFile(f1);
        Deploy.Config memory s = config("successor");
        s.oldBridge = r.bridge;
        s.predecessor = r.bridge;
        string memory f2 = s.file;
        Deploy.Result memory r2 = d.deploy(s);
        assertEq(r2.token, r.token, "the old token");
        assertTrue(r2.bridge != r.bridge);
        assertEq(address(WyecBridge(r2.bridge).predecessor()), r.bridge);
        assertEq(WrappedYcash(r.token).bridge(), r.bridge, "the hand-off is the guardians' act");
        string memory j = vm.readFile(f2);
        vm.removeFile(f2);
        assertEq(j.readAddress(".predecessor"), r.bridge);
        // a successor needs the old bridge to be the token's current one, and a predecessor
        s = config("successor");
        s.oldBridge = r.bridge;
        vm.expectRevert(bytes("a successor needs a PREDECESSOR"));
        d.deploy(s);
        s = config("bad");
        s.predecessor = r.bridge;
        vm.expectRevert(bytes("PREDECESSOR without OLD_BRIDGE"));
        d.deploy(s);
    }

    function test_Deploy_BadConfigRejected() public {
        Deploy d = new Deploy();
        Deploy.Config memory c = config("bad");
        c.challengeWindow = 0;
        vm.expectRevert(bytes("bad CHALLENGE_WINDOW"));
        d.deploy(c);

        c = config("bad");
        c.capWindow = 0;
        vm.expectRevert(bytes("CAP_WINDOW must be > 0 when MINT_CAP > 0"));
        d.deploy(c);

        c = config("bad");
        c.threshold = 4;
        vm.expectRevert(bytes("bad THRESHOLD"));
        d.deploy(c);
    }
}
