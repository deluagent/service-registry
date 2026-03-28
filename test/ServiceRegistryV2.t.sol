// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ServiceRegistryV2} from "../src/ServiceRegistryV2.sol";

/// @notice Full test suite for ServiceRegistryV2.
///         Covers all V1 behaviour + all new V2 features.
///         Must have >= 20 passing tests.
contract ServiceRegistryV2Test is Test {
    ServiceRegistryV2 registry;

    address owner    = makeAddr("owner");
    address serviceA = makeAddr("serviceA");
    address serviceB = makeAddr("serviceB");
    address serviceC = makeAddr("serviceC");
    address agent1   = makeAddr("agent1");
    address agent2   = makeAddr("agent2");
    address ach      = 0x0667988FeaceC78Ac397878758AE13f515303972;

    uint256 constant STAKE = 0.01 ether;

    bytes32 constant TAG_LLM        = keccak256("llm");
    bytes32 constant TAG_PRICE_FEED = keccak256("price-feed");
    bytes32 constant TAG_COMPUTE    = keccak256("compute");

    function setUp() public {
        registry = new ServiceRegistryV2(owner);
        vm.deal(serviceA, 10 ether);
        vm.deal(serviceB, 10 ether);
        vm.deal(serviceC, 10 ether);
        vm.deal(agent1, 1 ether);
        vm.deal(agent2, 1 ether);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _register(address svc, string memory name) internal returns (uint256 id) {
        vm.prank(svc);
        id = registry.register{value: STAKE}(
            name,
            "ipfs://capabilities",
            0.001 ether,
            ServiceRegistryV2.Category.Data
        );
    }

    function _registerWithCategory(address svc, string memory name, ServiceRegistryV2.Category cat)
        internal returns (uint256 id)
    {
        vm.prank(svc);
        id = registry.register{value: STAKE}(name, "ipfs://x", 0.001 ether, cat);
    }

    /// Pump up reputation by good-rating from many agents
    function _boostRep(uint256 id, uint256 times) internal {
        for (uint256 i; i < times; i++) {
            address rater = makeAddr(string(abi.encodePacked("booster", id, i)));
            vm.prank(rater);
            registry.rateService(id, 5, "");
        }
    }

    // ─── ═══════════════════════════════════════════════════════════════════ ───
    // ─── V1 COMPATIBILITY ────────────────────────────────────────────────────
    // ─── ═══════════════════════════════════════════════════════════════════ ───

    // test 01
    function test_V1_Register() public {
        uint256 id = _register(serviceA, "DataFeed Alpha");
        ServiceRegistryV2.Service memory svc = registry.getService(id);
        assertEq(svc.owner, serviceA);
        assertEq(svc.name, "DataFeed Alpha");
        uint256 expectedStake = STAKE - (STAKE * 500) / 10_000;
        assertEq(svc.stakedETH, expectedStake);
        assertEq(registry.treasuryBalance(), (STAKE * 500) / 10_000);
        assertEq(svc.reputationScore, registry.REPUTATION_START());
        assertTrue(svc.active);
    }

    // test 02
    function test_V1_InsufficientStakeReverts() public {
        vm.prank(serviceA);
        vm.expectRevert(abi.encodeWithSelector(
            ServiceRegistryV2.InsufficientStake.selector, 0.0001 ether, registry.MIN_STAKE()
        ));
        registry.register{value: 0.0001 ether}("cheap", "ipfs://x", 0, ServiceRegistryV2.Category.Other);
    }

    // test 03
    function test_V1_GoodRatingIncreasesReputation() public {
        uint256 id = _register(serviceA, "Good Service");
        uint256 repBefore = registry.getService(id).reputationScore;
        vm.prank(agent1);
        registry.rateService(id, 5, "ipfs://evidence");
        assertGt(registry.getService(id).reputationScore, repBefore);
        assertEq(registry.getService(id).goodResponses, 1);
    }

    // test 04
    function test_V1_BadRatingDecreasesReputation() public {
        uint256 id = _register(serviceA, "Bad Service");
        uint256 repBefore = registry.getService(id).reputationScore;
        vm.prank(agent1);
        registry.rateService(id, 1, "ipfs://bad");
        assertLt(registry.getService(id).reputationScore, repBefore);
        assertEq(registry.getService(id).badResponses, 1);
    }

    // test 05
    function test_V1_NeutralRatingNoChange() public {
        uint256 id = _register(serviceA, "Neutral");
        uint256 repBefore = registry.getService(id).reputationScore;
        vm.prank(agent1);
        registry.rateService(id, 3, "");
        assertEq(registry.getService(id).reputationScore, repBefore);
    }

    // test 06
    function test_V1_CannotRateOwn() public {
        uint256 id = _register(serviceA, "Self");
        vm.prank(serviceA);
        vm.expectRevert(ServiceRegistryV2.CannotRateOwn.selector);
        registry.rateService(id, 5, "");
    }

    // test 07
    function test_V1_RateLimitEnforced() public {
        uint256 id = _register(serviceA, "Rate Limited");
        vm.prank(agent1); registry.rateService(id, 5, "");
        vm.prank(agent1);
        vm.expectRevert();
        registry.rateService(id, 5, "");
    }

    // test 08
    function test_V1_RateAfter24Hours() public {
        uint256 id = _register(serviceA, "Time Service");
        vm.prank(agent1); registry.rateService(id, 5, "");
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(agent1); registry.rateService(id, 5, "");
        assertEq(registry.getService(id).goodResponses, 2);
    }

    // test 09
    function test_V1_AutoSlash() public {
        uint256 id = _register(serviceA, "Unreliable");
        uint256 threshold = registry.BAD_RESPONSE_THRESHOLD();
        uint256 stakeBefore = registry.getService(id).stakedETH;
        for (uint256 i; i < threshold; i++) {
            address rater = makeAddr(string(abi.encodePacked("rater", i)));
            vm.prank(rater);
            registry.rateService(id, 1, "ipfs://bad");
        }
        assertLt(registry.getService(id).stakedETH, stakeBefore);
        assertTrue(registry.getService(id).slashed);
    }

    // test 10
    function test_V1_ManualSlash() public {
        uint256 id = _register(serviceA, "To Slash");
        uint256 stakeBefore = registry.getService(id).stakedETH;
        vm.prank(owner);
        registry.slashService(id);
        assertLt(registry.getService(id).stakedETH, stakeBefore);
        assertGt(registry.treasuryBalance(), 0);
    }

    // test 11
    function test_V1_WithdrawAndExit() public {
        uint256 id = _register(serviceA, "Exiting");
        uint256 balBefore = serviceA.balance;
        vm.prank(serviceA);
        registry.withdrawAndExit(id);
        assertFalse(registry.getService(id).active);
        assertGt(serviceA.balance, balBefore);
    }

    // test 12
    function test_V1_GetServicesByCategory() public {
        _register(serviceA, "Data A");
        _register(serviceB, "Data B");
        (uint256[] memory ids, uint256 total) = registry.getServicesByCategory(
            ServiceRegistryV2.Category.Data, 0, 10
        );
        assertEq(total, 2);
        assertEq(ids.length, 2);
    }

    // ─── ═══════════════════════════════════════════════════════════════════ ───
    // ─── V2: ONLINE STATUS ────────────────────────────────────────────────────
    // ─── ═══════════════════════════════════════════════════════════════════ ───

    // test 13
    function test_V2_HeartbeatSetsOnline() public {
        uint256 id = _register(serviceA, "Online Svc");
        assertFalse(registry.isOnline(id)); // not online yet
        vm.prank(serviceA);
        registry.heartbeat(id);
        assertTrue(registry.isOnline(id));
    }

    // test 14
    function test_V2_HeartbeatExpires() public {
        uint256 id = _register(serviceA, "Expiry Svc");
        vm.prank(serviceA);
        registry.heartbeat(id);
        assertTrue(registry.isOnline(id));
        // Advance past TTL (5 min)
        vm.warp(block.timestamp + registry.HEARTBEAT_TTL() + 1);
        assertFalse(registry.isOnline(id));
    }

    // test 15
    function test_V2_SetOffline() public {
        uint256 id = _register(serviceA, "Go Offline");
        vm.prank(serviceA);
        registry.heartbeat(id);
        assertTrue(registry.isOnline(id));
        vm.prank(serviceA);
        registry.setOffline(id);
        assertFalse(registry.isOnline(id));
    }

    // test 16
    function test_V2_HeartbeatOnlyOwner() public {
        uint256 id = _register(serviceA, "Owner Only HB");
        vm.prank(agent1);
        vm.expectRevert(ServiceRegistryV2.NotServiceOwner.selector);
        registry.heartbeat(id);
    }

    // ─── ═══════════════════════════════════════════════════════════════════ ───
    // ─── V2: SKILL TAGS ───────────────────────────────────────────────────────
    // ─── ═══════════════════════════════════════════════════════════════════ ───

    // test 17
    function test_V2_SetAndCheckTags() public {
        uint256 id = _register(serviceA, "Tagged Svc");
        bytes32[] memory tags = new bytes32[](2);
        tags[0] = TAG_LLM;
        tags[1] = TAG_PRICE_FEED;
        vm.prank(serviceA);
        registry.setTags(id, tags);
        assertTrue(registry.hasTag(id, TAG_LLM));
        assertTrue(registry.hasTag(id, TAG_PRICE_FEED));
        assertFalse(registry.hasTag(id, TAG_COMPUTE));
    }

    // test 18
    function test_V2_TagsReplaced() public {
        uint256 id = _register(serviceA, "Tag Replace");
        bytes32[] memory tags1 = new bytes32[](1);
        tags1[0] = TAG_LLM;
        vm.prank(serviceA);
        registry.setTags(id, tags1);
        assertTrue(registry.hasTag(id, TAG_LLM));

        bytes32[] memory tags2 = new bytes32[](1);
        tags2[0] = TAG_PRICE_FEED;
        vm.prank(serviceA);
        registry.setTags(id, tags2);
        assertFalse(registry.hasTag(id, TAG_LLM));       // old tag gone
        assertTrue(registry.hasTag(id, TAG_PRICE_FEED)); // new tag present
    }

    // test 19
    function test_V2_TooManyTagsReverts() public {
        uint256 id = _register(serviceA, "Tag Overflow");
        bytes32[] memory tags = new bytes32[](9); // MAX_TAGS = 8
        for (uint256 i; i < 9; i++) tags[i] = bytes32(i + 1);
        vm.prank(serviceA);
        vm.expectRevert(ServiceRegistryV2.TooManyTags.selector);
        registry.setTags(id, tags);
    }

    // test 20
    function test_V2_SetTagsOnlyOwner() public {
        uint256 id = _register(serviceA, "Tag Auth");
        bytes32[] memory tags = new bytes32[](1);
        tags[0] = TAG_LLM;
        vm.prank(agent1);
        vm.expectRevert(ServiceRegistryV2.NotServiceOwner.selector);
        registry.setTags(id, tags);
    }

    // test 21
    function test_V2_GetServicesByTag() public {
        uint256 id1 = _register(serviceA, "LLM Service");
        uint256 id2 = _register(serviceB, "PriceFeed");
        uint256 id3 = _register(serviceC, "LLM Oracle");

        bytes32[] memory llmTag = new bytes32[](1);
        llmTag[0] = TAG_LLM;
        vm.prank(serviceA); registry.setTags(id1, llmTag);
        vm.prank(serviceC); registry.setTags(id3, llmTag);

        bytes32[] memory pfTag = new bytes32[](1);
        pfTag[0] = TAG_PRICE_FEED;
        vm.prank(serviceB); registry.setTags(id2, pfTag);

        uint256[] memory llmServices = registry.getServicesByTag(TAG_LLM, 10);
        assertEq(llmServices.length, 2);

        uint256[] memory pfServices = registry.getServicesByTag(TAG_PRICE_FEED, 10);
        assertEq(pfServices.length, 1);
        assertEq(pfServices[0], id2);
    }

    // ─── ═══════════════════════════════════════════════════════════════════ ───
    // ─── V2: JOB COMPLETION ───────────────────────────────────────────────────
    // ─── ═══════════════════════════════════════════════════════════════════ ───

    // test 22
    function test_V2_RecordJobCompletion_ByACH() public {
        uint256 id = _register(serviceA, "Job Svc");
        vm.prank(ach);
        registry.recordJobCompletion(id, agent1);
        ServiceRegistryV2.Service memory svc = registry.getService(id);
        assertEq(svc.successfulJobs, 1);
        assertEq(svc.uniqueBuyers, 1);
        assertTrue(registry.hasBought(id, agent1));
    }

    // test 23
    function test_V2_RecordJobCompletion_ByOwner() public {
        uint256 id = _register(serviceA, "Job Svc Owner");
        vm.prank(serviceA);
        registry.recordJobCompletion(id, agent2);
        assertEq(registry.getService(id).successfulJobs, 1);
    }

    // test 24
    function test_V2_UniquesBuyersTracked() public {
        uint256 id = _register(serviceA, "Unique Buyers");
        vm.startPrank(ach);
        registry.recordJobCompletion(id, agent1);
        registry.recordJobCompletion(id, agent1); // duplicate
        registry.recordJobCompletion(id, agent2); // new buyer
        vm.stopPrank();
        ServiceRegistryV2.Service memory svc = registry.getService(id);
        assertEq(svc.successfulJobs, 3);
        assertEq(svc.uniqueBuyers, 2); // agent1 counted once
    }

    // test 25
    function test_V2_RecordJob_Unauthorized() public {
        uint256 id = _register(serviceA, "Auth Check");
        vm.prank(agent1);
        vm.expectRevert(ServiceRegistryV2.NotAuthorized.selector);
        registry.recordJobCompletion(id, agent1);
    }

    // ─── ═══════════════════════════════════════════════════════════════════ ───
    // ─── V2: GRADUATION TIERS ─────────────────────────────────────────────────
    // ─── ═══════════════════════════════════════════════════════════════════ ───

    // test 26
    function test_V2_TierNone_Initially() public {
        uint256 id = _register(serviceA, "No Tier");
        assertEq(uint8(registry.getTier(id)), uint8(ServiceRegistryV2.Tier.None));
    }

    // test 27
    function test_V2_TierBronze() public {
        uint256 id = _register(serviceA, "Bronze Svc");
        // Need rep >= 4000. Default is 5000 so that's fine.
        // Need successfulJobs >= 1
        vm.prank(ach);
        registry.recordJobCompletion(id, agent1);
        assertEq(uint8(registry.getTier(id)), uint8(ServiceRegistryV2.Tier.Bronze));
    }

    // test 28
    function test_V2_TierSilver() public {
        uint256 id = _register(serviceA, "Silver Svc");
        // rep >= 5000 (default = 5000 exactly)
        for (uint256 i; i < 5; i++) {
            vm.prank(ach);
            registry.recordJobCompletion(id, makeAddr(string(abi.encodePacked("buyer", i))));
        }
        assertEq(uint8(registry.getTier(id)), uint8(ServiceRegistryV2.Tier.Silver));
    }

    // test 29
    function test_V2_TierGold() public {
        uint256 id = _register(serviceA, "Gold Svc");
        // Boost rep to >= 7000 (need 20 more good ratings from start of 5000)
        // Each good rating = +100, so 20 good ratings = 7000
        _boostRep(id, 20);
        assertGe(registry.getService(id).reputationScore, 7000);

        for (uint256 i; i < 20; i++) {
            vm.prank(ach);
            registry.recordJobCompletion(id, makeAddr(string(abi.encodePacked("goldbuyer", i))));
        }
        assertEq(uint8(registry.getTier(id)), uint8(ServiceRegistryV2.Tier.Gold));
    }

    // test 30
    function test_V2_TierPlatinum() public {
        uint256 id = _register(serviceA, "Platinum Svc");
        // Boost rep to >= 9000 (need +4000 from 5000 = 40 good ratings)
        _boostRep(id, 40);
        assertGe(registry.getService(id).reputationScore, 9000);

        for (uint256 i; i < 50; i++) {
            vm.prank(ach);
            registry.recordJobCompletion(id, makeAddr(string(abi.encodePacked("platbuyer", i))));
        }
        assertEq(uint8(registry.getTier(id)), uint8(ServiceRegistryV2.Tier.Platinum));
    }

    // test 31
    function test_V2_TierRequiresRepThreshold() public {
        uint256 id = _register(serviceA, "Low Rep");
        // Damage reputation below 4000
        // Default is 5000; bad rating = -500; need at least 3 bad ratings to go below 4000
        for (uint256 i; i < 3; i++) {
            address rater = makeAddr(string(abi.encodePacked("br", i)));
            vm.prank(rater);
            registry.rateService(id, 1, "");
        }
        assertLt(registry.getService(id).reputationScore, 4000);

        // Record 1 job — but rep is too low for Bronze
        vm.prank(ach);
        registry.recordJobCompletion(id, agent1);
        assertEq(uint8(registry.getTier(id)), uint8(ServiceRegistryV2.Tier.None));
    }

    // ─── ═══════════════════════════════════════════════════════════════════ ───
    // ─── V2: DISCOVERY HELPERS ────────────────────────────────────────────────
    // ─── ═══════════════════════════════════════════════════════════════════ ───

    // test 32
    function test_V2_GetTopByReputation() public {
        uint256 idA = _register(serviceA, "Low Rep");
        uint256 idB = _register(serviceB, "High Rep");
        uint256 idC = _register(serviceC, "Mid Rep");

        // Boost B a lot, C a bit
        _boostRep(idB, 20);
        _boostRep(idC, 5);

        uint256[] memory top = registry.getTopByReputation(3);
        assertEq(top.length, 3);
        // First should be highest rep
        assertGe(
            registry.getService(top[0]).reputationScore,
            registry.getService(top[1]).reputationScore
        );
        assertGe(
            registry.getService(top[1]).reputationScore,
            registry.getService(top[2]).reputationScore
        );
    }

    // test 33
    function test_V2_GetTopByReputation_Limit() public {
        _register(serviceA, "Svc A");
        _register(serviceB, "Svc B");
        _register(serviceC, "Svc C");

        uint256[] memory top2 = registry.getTopByReputation(2);
        assertEq(top2.length, 2);
    }

    // test 34
    function test_V2_GetOnlineServices() public {
        uint256 idA = _register(serviceA, "Online A");
        uint256 idB = _register(serviceB, "Online B");
        _register(serviceC, "Offline C");

        vm.prank(serviceA); registry.heartbeat(idA);
        vm.prank(serviceB); registry.heartbeat(idB);
        // serviceC never heartbeats

        uint256[] memory online = registry.getOnlineServices(10);
        assertEq(online.length, 2);
    }

    // test 35
    function test_V2_GetOnlineServices_Limit() public {
        uint256 idA = _register(serviceA, "Online A");
        uint256 idB = _register(serviceB, "Online B");
        uint256 idC = _register(serviceC, "Online C");

        vm.prank(serviceA); registry.heartbeat(idA);
        vm.prank(serviceB); registry.heartbeat(idB);
        vm.prank(serviceC); registry.heartbeat(idC);

        uint256[] memory online = registry.getOnlineServices(2);
        assertEq(online.length, 2);
    }

    // test 36
    function test_V2_GetOnlineServices_ExcludesExpired() public {
        uint256 idA = _register(serviceA, "Fast Expiry");
        vm.prank(serviceA);
        registry.heartbeat(idA);

        // Advance past TTL
        vm.warp(block.timestamp + registry.HEARTBEAT_TTL() + 1);

        uint256[] memory online = registry.getOnlineServices(10);
        assertEq(online.length, 0);
    }

    // ─── ═══════════════════════════════════════════════════════════════════ ───
    // ─── FUZZ ─────────────────────────────────────────────────────────────────
    // ─── ═══════════════════════════════════════════════════════════════════ ───

    // test 37
    function testFuzz_ReputationNeverExceedsMax(uint8 score) public {
        score = uint8(bound(score, 1, 5));
        uint256 id = _register(serviceA, "Fuzz Rep");
        for (uint256 i; i < 20; i++) {
            address rater = makeAddr(string(abi.encodePacked("fuzzrater", i)));
            vm.prank(rater);
            registry.rateService(id, score, "");
        }
        assertLe(registry.getService(id).reputationScore, registry.REPUTATION_MAX());
    }

    // test 38
    function testFuzz_TierMonotonicallyIncreases(uint256 jobs) public {
        jobs = bound(jobs, 0, 60);
        uint256 id = _register(serviceA, "Fuzz Tier");
        _boostRep(id, 50); // get rep above 9000

        for (uint256 i; i < jobs; i++) {
            vm.prank(ach);
            registry.recordJobCompletion(id, makeAddr(string(abi.encodePacked("fuzzbuyer", i))));
        }

        ServiceRegistryV2.Tier tier = registry.getTier(id);
        // Tier value is non-decreasing with jobs (given rep is maxed)
        if (jobs >= 50) assertEq(uint8(tier), uint8(ServiceRegistryV2.Tier.Platinum));
        else if (jobs >= 20) assertEq(uint8(tier), uint8(ServiceRegistryV2.Tier.Gold));
        else if (jobs >= 5)  assertEq(uint8(tier), uint8(ServiceRegistryV2.Tier.Silver));
        else if (jobs >= 1)  assertEq(uint8(tier), uint8(ServiceRegistryV2.Tier.Bronze));
        else                  assertEq(uint8(tier), uint8(ServiceRegistryV2.Tier.None));
    }

    // test 39
    function test_V2_GetTags_Empty() public {
        uint256 id = _register(serviceA, "No Tags");
        bytes32[] memory tags = registry.getTags(id);
        assertEq(tags.length, 0);
    }

    // test 40
    function test_V2_MaxEightTags() public {
        uint256 id = _register(serviceA, "Max Tags");
        bytes32[] memory tags = new bytes32[](8);
        for (uint256 i; i < 8; i++) tags[i] = bytes32(i + 1);
        vm.prank(serviceA);
        registry.setTags(id, tags); // should succeed
        bytes32[] memory result = registry.getTags(id);
        assertEq(result.length, 8);
    }
}
