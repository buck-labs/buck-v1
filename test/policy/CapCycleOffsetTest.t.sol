// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PolicyManager} from "src/policy/PolicyManager.sol";

contract PolicyManagerHarness is PolicyManager {
    function exposedCurrentCapCycle() external view returns (uint64) {
        return _currentCapCycle();
    }
}

contract CapCycleOffsetTest is Test {
    PolicyManagerHarness internal policy;
    address internal admin = address(this);

    function setUp() public {
        // Deploy harness via proxy to exercise initializer
        PolicyManagerHarness implementation = new PolicyManagerHarness();
        bytes memory initData = abi.encodeCall(implementation.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        policy = PolicyManagerHarness(address(proxy));
    }

    function test_DefaultOffsetIsEST() public view {
        // 19 hours = EST (UTC-5 means add 19 to shift midnight)
        assertEq(policy.cycleOffsetHours(), 19, "Default offset should be 19 (EST)");
    }

    function test_Revert_InvalidCycleOffsetBounds() public {
        // Valid range is 0-23 hours
        vm.expectRevert(PolicyManager.InvalidCycleOffset.selector);
        vm.prank(admin);
        policy.setCycleOffsetHours(24);

        vm.expectRevert(PolicyManager.InvalidCycleOffset.selector);
        vm.prank(admin);
        policy.setCycleOffsetHours(100);
    }

    function test_CapCycleResetsWhenOffsetChangesAcrossBoundary() public {
        // EST midnight = 05:00 UTC. At 04:30 UTC, we're still in the previous EST day.
        // EDT midnight = 04:00 UTC. At 04:30 UTC, we're in the new EDT day.
        uint256 time = 4 hours + 30 minutes; // 04:30 UTC
        vm.warp(time);

        // With 19h offset (EST): (4.5h + 19h) / 24h = 23.5h / 24h = 0
        uint64 cycleEST = policy.exposedCurrentCapCycle();
        assertEq(cycleEST, 0, "Should be cycle 0 before EST midnight");

        // Switch to EDT (20 hours offset)
        vm.prank(admin);
        policy.setCycleOffsetHours(20);

        // With 20h offset (EDT): (4.5h + 20h) / 24h = 24.5h / 24h = 1
        uint64 cycleEDT = policy.exposedCurrentCapCycle();
        assertEq(cycleEDT, 1, "Should be cycle 1 after EDT midnight");
    }

    function test_CapCycleCalculatesWithConfiguredOffset() public {
        // At exactly 05:00 UTC with EST offset (19h), should be start of cycle 1
        // (5h + 19h) / 24h = 24h / 24h = 1
        vm.warp(5 hours);
        uint64 cycleEST = policy.exposedCurrentCapCycle();
        assertEq(cycleEST, 1, "Cycle should roll at midnight EST (05:00 UTC)");

        // Switch to EDT (20h) and check 04:00 UTC
        vm.prank(admin);
        policy.setCycleOffsetHours(20);
        vm.warp(4 hours);
        // (4h + 20h) / 24h = 24h / 24h = 1
        uint64 cycleEDT = policy.exposedCurrentCapCycle();
        assertEq(cycleEDT, 1, "Cycle should roll at midnight EDT (04:00 UTC)");
    }

    function test_CycleWorksWithLowTimestamp() public {
        // Even at timestamp=1, adding hours keeps it positive
        vm.warp(1);
        // (1 + 19*3600) / 86400 = 68401 / 86400 = 0
        uint64 cycle = policy.exposedCurrentCapCycle();
        assertEq(cycle, 0, "Should work with low timestamps");
    }
}
