// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";

contract ServiceRegistryTest is Test {
    ServiceRegistry registry;

    address owner   = makeAddr("owner");
    address serviceA = makeAddr("serviceA");
    address serviceB = makeAddr("serviceB");
    address agent1  = makeAddr("agent1");
    address agent2  = makeAddr("agent2");

    uint256 constant STAKE = 0.01 ether;

    function setUp() public {
        registry = new ServiceRegistry(owner);
        vm.deal(serviceA, 1 ether);
        vm.deal(serviceB, 1 ether);
        vm.deal(agent1, 1 ether);
    }

    function _register(address svc, string memory name) internal returns (uint256 id) {
        vm.prank(svc);
        id = registry.register{value: STAKE}(
            name,
            "ipfs://capabilities",
            0.001 ether,
            ServiceRegistry.Category.Data
        );
    }

    function test_Register() public {
        uint256 id = _register(serviceA, "DataFeed Alpha");
        ServiceRegistry.Service memory svc = registry.getService(id);
        assertEq(svc.owner, serviceA);
        assertEq(svc.name, "DataFeed Alpha");
        // 5% registration fee goes to treasury; net stake = 95%
        uint256 expectedStake = STAKE - (STAKE * 500) / 10_000;
        assertEq(svc.stakedETH, expectedStake);
        assertEq(registry.treasuryBalance(), (STAKE * 500) / 10_000);
        assertEq(svc.reputationScore, registry.REPUTATION_START());
        assertTrue(svc.active);
    }

    function test_InsufficientStakeReverts() public {
        vm.prank(serviceA);
        vm.expectRevert(abi.encodeWithSelector(
            ServiceRegistry.InsufficientStake.selector, 0.0001 ether, registry.MIN_STAKE()
        ));
        registry.register{value: 0.0001 ether}("cheap", "ipfs://x", 0, ServiceRegistry.Category.Other);
    }

    function test_GoodRatingIncreasesReputation() public {
        uint256 id = _register(serviceA, "Good Service");
        uint256 repBefore = registry.getService(id).reputationScore;

        vm.prank(agent1);
        registry.rateService(id, 5, "ipfs://evidence");

        uint256 repAfter = registry.getService(id).reputationScore;
        assertGt(repAfter, repBefore);
        assertEq(registry.getService(id).goodResponses, 1);
    }

    function test_BadRatingDecreasesReputation() public {
        uint256 id = _register(serviceA, "Bad Service");
        uint256 repBefore = registry.getService(id).reputationScore;

        vm.prank(agent1);
        registry.rateService(id, 1, "ipfs://bad-evidence");

        uint256 repAfter = registry.getService(id).reputationScore;
        assertLt(repAfter, repBefore);
        assertEq(registry.getService(id).badResponses, 1);
    }

    function test_NeutralRatingNoChange() public {
        uint256 id = _register(serviceA, "Neutral Service");
        uint256 repBefore = registry.getService(id).reputationScore;

        vm.prank(agent1);
        registry.rateService(id, 3, "");

        assertEq(registry.getService(id).reputationScore, repBefore);
    }

    function test_CannotRateOwnService() public {
        uint256 id = _register(serviceA, "Self Rater");
        vm.prank(serviceA);
        vm.expectRevert(ServiceRegistry.CannotRateOwn.selector);
        registry.rateService(id, 5, "");
    }

    function test_RateLimitEnforced() public {
        uint256 id = _register(serviceA, "Rate Limited");
        vm.prank(agent1);
        registry.rateService(id, 5, "");

        vm.prank(agent1);
        vm.expectRevert(); // RatingTooSoon
        registry.rateService(id, 5, "");
    }

    function test_RateAfter24Hours() public {
        uint256 id = _register(serviceA, "Time Service");
        vm.prank(agent1);
        registry.rateService(id, 5, "");

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(agent1);
        registry.rateService(id, 5, ""); // should work
        assertEq(registry.getService(id).goodResponses, 2);
    }

    function test_AutoSlashAfterThresholdBadRatings() public {
        uint256 id = _register(serviceA, "Unreliable");
        uint256 threshold = registry.BAD_RESPONSE_THRESHOLD();
        uint256 stakeBefore = registry.getService(id).stakedETH;

        // Generate `threshold` bad ratings from different agents
        for (uint256 i; i < threshold; i++) {
            address rater = makeAddr(string(abi.encodePacked("rater", i)));
            vm.prank(rater);
            registry.rateService(id, 1, "ipfs://bad");
        }

        uint256 stakeAfter = registry.getService(id).stakedETH;
        assertLt(stakeAfter, stakeBefore); // stake slashed
        assertTrue(registry.getService(id).slashed);
    }

    function test_ManualSlash() public {
        uint256 id = _register(serviceA, "To Slash");
        uint256 stakeBefore = registry.getService(id).stakedETH;

        vm.prank(owner);
        registry.slashService(id);

        assertLt(registry.getService(id).stakedETH, stakeBefore);
        assertGt(registry.treasuryBalance(), 0);
    }

    function test_WithdrawAndExit() public {
        uint256 id = _register(serviceA, "Exiting");
        uint256 balBefore = serviceA.balance;

        vm.prank(serviceA);
        registry.withdrawAndExit(id);

        assertFalse(registry.getService(id).active);
        assertGt(serviceA.balance, balBefore);
    }

    function test_GetServicesByCategory() public {
        _register(serviceA, "Data A");
        _register(serviceB, "Data B");

        (uint256[] memory ids, uint256 total) = registry.getServicesByCategory(
            ServiceRegistry.Category.Data, 0, 10
        );
        assertEq(total, 2);
        assertEq(ids.length, 2);
    }

    function test_InvalidScoreReverts() public {
        uint256 id = _register(serviceA, "Score Test");
        vm.prank(agent1);
        vm.expectRevert(ServiceRegistry.InvalidScore.selector);
        registry.rateService(id, 6, ""); // max is 5
    }

    function testFuzz_ReputationNeverExceedsMax(uint8 score) public {
        score = uint8(bound(score, 1, 5));
        uint256 id = _register(serviceA, "Fuzz");

        // Rate 100 times from different agents
        for (uint256 i; i < 20; i++) {
            address rater = makeAddr(string(abi.encodePacked("fuzzer", i)));
            vm.prank(rater);
            registry.rateService(id, score, "");
        }

        assertLe(registry.getService(id).reputationScore, registry.REPUTATION_MAX());
    }
}
