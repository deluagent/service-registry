// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ServiceRegistryV2
/// @notice Extends ServiceRegistry with online status, skill tags, job tracking,
///         and graduation tiers — inspired by Virtual Protocol's ACP.
///
/// @dev New features in V2:
///   1. **Online status** — Services heartbeat to signal availability.
///      A service is considered online if it heartbeated within the last 5 minutes.
///   2. **Skill tags** — Up to 8 bytes32 tags per service (keccak256 of human-readable labels).
///      Enables fast onchain filtering: hasTag, getServicesByTag.
///   3. **Job completion tracking** — ACH or service owner records completed jobs.
///      Tracks successfulJobs and uniqueBuyers. Powers graduation tier logic.
///   4. **Graduation tiers** — Bronze/Silver/Gold/Platinum computed from jobs + reputation.
///      Inspired by Virtual Protocol's ACP agent graduation framework.
///   5. **Discovery helpers** — getServicesByTag, getTopByReputation, getOnlineServices.

contract ServiceRegistryV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant MIN_STAKE              = 0.001 ether;
    uint256 public constant SLASH_BPS              = 2000;   // 20% slash per incident
    uint256 public constant REGISTRATION_FEE_BPS   = 500;    // 5% of stake → protocol treasury
    uint256 public constant MAX_PROTOCOL_FEE_BPS   = 1000;   // 10% max (governance bound)
    uint256 public constant BAD_RESPONSE_THRESHOLD = 10;     // slash after 10 bad ratings
    uint256 public constant REPUTATION_START       = 5000;   // 50/100
    uint256 public constant REPUTATION_MAX         = 10000;
    uint256 public constant REPUTATION_GOOD        = 100;    // +1% per good rating
    uint256 public constant REPUTATION_BAD         = 500;    // -5% per bad rating

    // V2: heartbeat expiry
    uint256 public constant HEARTBEAT_TTL = 5 minutes;

    // V2: ACH address that can record job completions
    address public constant ACH_ADDRESS = 0x0667988FeaceC78Ac397878758AE13f515303972;

    // V2: max tags per service
    uint256 public constant MAX_TAGS = 8;

    // ─── Types ────────────────────────────────────────────────────────────────
    enum Category {
        Data,
        Compute,
        Storage,
        Oracle,
        Identity,
        Other
    }

    /// @notice Graduation tier — computed from successfulJobs + reputationScore.
    ///         Inspired by Virtual Protocol's ACP agent graduation framework.
    enum Tier { None, Bronze, Silver, Gold, Platinum }

    struct Service {
        // ── V1 fields (order preserved) ──────────────────────────────────────
        address owner;
        string  name;
        string  capabilitiesURI;  // JSON: {endpoint, description, pricePerCall, inputSchema, outputSchema}
        uint256 pricePerCallWei;  // machine-readable price (x402 compatible)
        Category category;
        uint256 stakedETH;
        uint256 reputationScore; // 0-10000 (basis points of 100)
        uint256 totalCalls;
        uint256 goodResponses;
        uint256 badResponses;
        uint256 registeredAt;
        bool    active;
        bool    slashed;
        // ── V2 fields ─────────────────────────────────────────────────────────
        bool    online;          // set by heartbeat(), cleared by setOffline() or timeout
        uint256 lastHeartbeat;   // block.timestamp of last heartbeat
        bytes32[] tags;          // skill tags (max 8), e.g. keccak256("llm"), keccak256("price-feed")
        uint256 successfulJobs;  // recorded by ACH or owner
        uint256 uniqueBuyers;    // count of distinct buyer addresses
    }

    struct Rating {
        address rater;
        uint256 serviceId;
        uint8   score;        // 1-5
        string  evidenceURI;  // IPFS hash of response evidence
        uint256 timestamp;
    }

    // ─── State ────────────────────────────────────────────────────────────────
    uint256 public serviceCount;
    mapping(uint256 => Service) public services;
    mapping(uint256 => Rating[]) public serviceRatings;
    mapping(address => uint256[]) public ownerServices;

    // Prevent spam: one rating per agent per service per day
    mapping(address => mapping(uint256 => uint256)) public lastRatingTime;

    uint256 public treasuryBalance;

    // V2: job tracking — serviceId => buyer => bool
    mapping(uint256 => mapping(address => bool)) public hasBought;

    // ─── Events ───────────────────────────────────────────────────────────────
    // V1 events (preserved)
    event ServiceRegistered(uint256 indexed id, address indexed owner, string name, Category category);
    event ServiceUpdated(uint256 indexed id, string capabilitiesURI, uint256 pricePerCallWei);
    event ServiceRated(uint256 indexed id, address indexed rater, uint8 score, string evidenceURI);
    event ServiceSlashed(uint256 indexed id, uint256 slashAmount);
    event ServiceDeactivated(uint256 indexed id);
    event StakeIncreased(uint256 indexed id, uint256 amount);
    event StakeWithdrawn(uint256 indexed id, uint256 amount);

    // V2 events
    event Heartbeat(uint256 indexed id);
    event TagsUpdated(uint256 indexed id);
    event JobCompleted(uint256 indexed id, address buyer);
    event TierUpgraded(uint256 indexed id, Tier tier);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error InsufficientStake(uint256 provided, uint256 required);
    error NotServiceOwner();
    error ServiceNotActive();
    error ServiceSlashedError();
    error InvalidScore();
    error RatingTooSoon(uint256 nextAllowed);
    error NotFound();
    error CannotRateOwn();
    // V2 errors
    error TooManyTags();
    error NotAuthorized();

    constructor(address owner_) Ownable(owner_) {}

    // ─── Register ─────────────────────────────────────────────────────────────

    /// @notice Register a new service. Stake ETH to get listed.
    function register(
        string calldata name,
        string calldata capabilitiesURI,
        uint256 pricePerCallWei,
        Category category
    ) external payable returns (uint256 id) {
        if (msg.value < MIN_STAKE) revert InsufficientStake(msg.value, MIN_STAKE);

        // Protocol fee: 5% of stake → treasury
        uint256 protocolFee = (msg.value * REGISTRATION_FEE_BPS) / 10_000;
        uint256 stakedAmount = msg.value - protocolFee;
        treasuryBalance += protocolFee;

        id = serviceCount++;
        // Initialise — V2 fields get zero values (online=false, lastHeartbeat=0, tags=[], etc.)
        Service storage svc = services[id];
        svc.owner           = msg.sender;
        svc.name            = name;
        svc.capabilitiesURI = capabilitiesURI;
        svc.pricePerCallWei = pricePerCallWei;
        svc.category        = category;
        svc.stakedETH       = stakedAmount;
        svc.reputationScore = REPUTATION_START;
        svc.registeredAt    = block.timestamp;
        svc.active          = true;

        ownerServices[msg.sender].push(id);

        emit ServiceRegistered(id, msg.sender, name, category);
    }

    // ─── Update ───────────────────────────────────────────────────────────────

    function updateCapabilities(
        uint256 id,
        string calldata capabilitiesURI,
        uint256 pricePerCallWei
    ) external {
        Service storage svc = _getActive(id);
        if (svc.owner != msg.sender) revert NotServiceOwner();
        svc.capabilitiesURI = capabilitiesURI;
        svc.pricePerCallWei = pricePerCallWei;
        emit ServiceUpdated(id, capabilitiesURI, pricePerCallWei);
    }

    function addStake(uint256 id) external payable {
        Service storage svc = _getActive(id);
        if (svc.owner != msg.sender) revert NotServiceOwner();
        svc.stakedETH += msg.value;
        emit StakeIncreased(id, msg.value);
    }

    // ─── Rate ─────────────────────────────────────────────────────────────────

    /// @notice Rate a service after calling it. Score 1-5.
    function rateService(
        uint256 id,
        uint8 score,
        string calldata evidenceURI
    ) external {
        if (score == 0 || score > 5) revert InvalidScore();

        Service storage svc = services[id];
        if (!svc.active) revert ServiceNotActive();
        if (svc.owner == msg.sender) revert CannotRateOwn();

        uint256 last = lastRatingTime[msg.sender][id];
        if (last != 0) {
            uint256 nextAllowed = last + 24 hours;
            if (block.timestamp < nextAllowed) revert RatingTooSoon(nextAllowed);
        }

        lastRatingTime[msg.sender][id] = block.timestamp;

        serviceRatings[id].push(Rating({
            rater:       msg.sender,
            serviceId:   id,
            score:       score,
            evidenceURI: evidenceURI,
            timestamp:   block.timestamp
        }));

        svc.totalCalls++;

        if (score >= 4) {
            svc.goodResponses++;
            svc.reputationScore = _min(svc.reputationScore + REPUTATION_GOOD, REPUTATION_MAX);
        } else if (score <= 2) {
            svc.badResponses++;
            svc.reputationScore = svc.reputationScore > REPUTATION_BAD
                ? svc.reputationScore - REPUTATION_BAD
                : 0;
            if (svc.badResponses % BAD_RESPONSE_THRESHOLD == 0) {
                _slash(id, svc);
            }
        }

        emit ServiceRated(id, msg.sender, score, evidenceURI);
    }

    // ─── Slash ────────────────────────────────────────────────────────────────

    function slashService(uint256 id) external onlyOwner {
        Service storage svc = services[id];
        if (!svc.active) revert ServiceNotActive();
        _slash(id, svc);
    }

    function _slash(uint256 id, Service storage svc) internal {
        uint256 slashAmount = (svc.stakedETH * SLASH_BPS) / 10000;
        svc.stakedETH -= slashAmount;
        treasuryBalance += slashAmount;
        svc.slashed = true;

        if (svc.stakedETH < MIN_STAKE) {
            svc.active = false;
            emit ServiceDeactivated(id);
        }

        emit ServiceSlashed(id, slashAmount);
    }

    // ─── Withdraw / Exit ──────────────────────────────────────────────────────

    function withdrawAndExit(uint256 id) external nonReentrant {
        Service storage svc = services[id];
        if (svc.owner != msg.sender) revert NotServiceOwner();

        uint256 amount = svc.stakedETH;
        svc.stakedETH = 0;
        svc.active = false;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");

        emit ServiceDeactivated(id);
        emit StakeWithdrawn(id, amount);
    }

    // ─── V2: Online Status ────────────────────────────────────────────────────

    /// @notice Signal liveness. Sets online=true and records block.timestamp.
    ///         Service is considered offline if no heartbeat within HEARTBEAT_TTL (5 min).
    function heartbeat(uint256 serviceId) external {
        Service storage svc = services[serviceId];
        if (serviceId >= serviceCount) revert NotFound();
        if (svc.owner != msg.sender) revert NotServiceOwner();
        svc.online = true;
        svc.lastHeartbeat = block.timestamp;
        emit Heartbeat(serviceId);
    }

    /// @notice Explicitly mark a service offline.
    function setOffline(uint256 serviceId) external {
        if (serviceId >= serviceCount) revert NotFound();
        Service storage svc = services[serviceId];
        if (svc.owner != msg.sender) revert NotServiceOwner();
        svc.online = false;
        emit Heartbeat(serviceId); // reuse event — consumers re-read to see online=false
    }

    /// @notice Returns true iff service is online AND heartbeat is within TTL.
    function isOnline(uint256 id) external view returns (bool) {
        if (id >= serviceCount) revert NotFound();
        Service storage svc = services[id];
        return svc.online && (block.timestamp <= svc.lastHeartbeat + HEARTBEAT_TTL);
    }

    // ─── V2: Skill Tags ───────────────────────────────────────────────────────

    /// @notice Set skill tags for a service. Replaces existing tags. Max 8.
    ///         Use keccak256(abi.encodePacked("tag-name")) as tag values.
    function setTags(uint256 serviceId, bytes32[] calldata tags) external {
        if (serviceId >= serviceCount) revert NotFound();
        Service storage svc = services[serviceId];
        if (svc.owner != msg.sender) revert NotServiceOwner();
        if (tags.length > MAX_TAGS) revert TooManyTags();

        delete svc.tags;
        for (uint256 i; i < tags.length; i++) {
            svc.tags.push(tags[i]);
        }
        emit TagsUpdated(serviceId);
    }

    /// @notice Returns true if a service has a specific tag.
    function hasTag(uint256 serviceId, bytes32 tag) external view returns (bool) {
        if (serviceId >= serviceCount) revert NotFound();
        bytes32[] storage tags = services[serviceId].tags;
        for (uint256 i; i < tags.length; i++) {
            if (tags[i] == tag) return true;
        }
        return false;
    }

    /// @notice Returns the tags for a service.
    function getTags(uint256 serviceId) external view returns (bytes32[] memory) {
        if (serviceId >= serviceCount) revert NotFound();
        return services[serviceId].tags;
    }

    // ─── V2: Job Completion ───────────────────────────────────────────────────

    /// @notice Record a successful job completion. Callable by ACH or service owner.
    ///         Increments successfulJobs and tracks uniqueBuyers.
    function recordJobCompletion(uint256 serviceId, address buyer) external {
        if (serviceId >= serviceCount) revert NotFound();
        Service storage svc = services[serviceId];

        // Only ACH or service owner may record completions
        if (msg.sender != ACH_ADDRESS && msg.sender != svc.owner) revert NotAuthorized();

        svc.successfulJobs++;

        if (!hasBought[serviceId][buyer]) {
            hasBought[serviceId][buyer] = true;
            svc.uniqueBuyers++;
        }

        // Check if tier has changed and emit TierUpgraded if so
        Tier newTier = _computeTier(svc.successfulJobs, svc.reputationScore);
        if (uint8(newTier) > 0) {
            emit TierUpgraded(serviceId, newTier);
        }

        emit JobCompleted(serviceId, buyer);
    }

    // ─── V2: Graduation Tiers ─────────────────────────────────────────────────

    /// @notice Compute the graduation tier for a service — purely a view.
    ///         Tiers are not stored; they are derived from live state.
    ///
    ///   Bronze:   successfulJobs >= 1  && reputationScore >= 4000
    ///   Silver:   successfulJobs >= 5  && reputationScore >= 5000
    ///   Gold:     successfulJobs >= 20 && reputationScore >= 7000
    ///   Platinum: successfulJobs >= 50 && reputationScore >= 9000
    function getTier(uint256 serviceId) external view returns (Tier) {
        if (serviceId >= serviceCount) revert NotFound();
        Service storage svc = services[serviceId];
        return _computeTier(svc.successfulJobs, svc.reputationScore);
    }

    function _computeTier(uint256 jobs, uint256 rep) internal pure returns (Tier) {
        if (jobs >= 50 && rep >= 9000) return Tier.Platinum;
        if (jobs >= 20 && rep >= 7000) return Tier.Gold;
        if (jobs >= 5  && rep >= 5000) return Tier.Silver;
        if (jobs >= 1  && rep >= 4000) return Tier.Bronze;
        return Tier.None;
    }

    // ─── V2: Discovery Helpers ────────────────────────────────────────────────

    /// @notice Get up to `limit` active service IDs that have the given tag.
    function getServicesByTag(bytes32 tag, uint256 limit) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](serviceCount);
        uint256 count;

        for (uint256 i; i < serviceCount && count < limit; i++) {
            if (!services[i].active) continue;
            bytes32[] storage tags = services[i].tags;
            for (uint256 j; j < tags.length; j++) {
                if (tags[j] == tag) {
                    temp[count++] = i;
                    break;
                }
            }
        }

        uint256[] memory result = new uint256[](count);
        for (uint256 i; i < count; i++) result[i] = temp[i];
        return result;
    }

    /// @notice Get up to `limit` active service IDs sorted by reputation descending.
    ///         Uses insertion sort — suitable for small registries (< 500 services).
    function getTopByReputation(uint256 limit) external view returns (uint256[] memory) {
        uint256[] memory active = new uint256[](serviceCount);
        uint256 count;

        for (uint256 i; i < serviceCount; i++) {
            if (services[i].active) active[count++] = i;
        }

        // Insertion sort by reputationScore desc
        for (uint256 i = 1; i < count; i++) {
            uint256 key = active[i];
            uint256 keyRep = services[key].reputationScore;
            int256 j = int256(i) - 1;
            while (j >= 0 && services[active[uint256(j)]].reputationScore < keyRep) {
                active[uint256(j + 1)] = active[uint256(j)];
                j--;
            }
            active[uint256(j + 1)] = key;
        }

        uint256 resultLen = _min(limit, count);
        uint256[] memory result = new uint256[](resultLen);
        for (uint256 i; i < resultLen; i++) result[i] = active[i];
        return result;
    }

    /// @notice Get up to `limit` service IDs that are currently online (within TTL).
    function getOnlineServices(uint256 limit) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](serviceCount);
        uint256 count;

        for (uint256 i; i < serviceCount && count < limit; i++) {
            if (
                services[i].active &&
                services[i].online &&
                block.timestamp <= services[i].lastHeartbeat + HEARTBEAT_TTL
            ) {
                temp[count++] = i;
            }
        }

        uint256[] memory result = new uint256[](count);
        for (uint256 i; i < count; i++) result[i] = temp[i];
        return result;
    }

    // ─── V1 Discovery (preserved) ─────────────────────────────────────────────

    function getServicesByCategory(
        Category category,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory ids, uint256 total) {
        uint256[] memory temp = new uint256[](serviceCount);
        uint256 count;

        for (uint256 i; i < serviceCount; i++) {
            if (services[i].active && services[i].category == category) {
                temp[count++] = i;
            }
        }

        total = count;
        uint256 end = _min(offset + limit, count);
        ids = new uint256[](end > offset ? end - offset : 0);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = temp[i];
        }
    }

    function getService(uint256 id) external view returns (Service memory) {
        if (id >= serviceCount) revert NotFound();
        return services[id];
    }

    function getRatings(uint256 id) external view returns (Rating[] memory) {
        return serviceRatings[id];
    }

    function getOwnerServices(address owner_) external view returns (uint256[] memory) {
        return ownerServices[owner_];
    }

    // ─── Treasury ─────────────────────────────────────────────────────────────

    function withdrawTreasury(address payable to) external onlyOwner {
        uint256 amount = treasuryBalance;
        treasuryBalance = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _getActive(uint256 id) internal view returns (Service storage svc) {
        if (id >= serviceCount) revert NotFound();
        svc = services[id];
        if (!svc.active) revert ServiceNotActive();
        if (svc.slashed) revert ServiceSlashedError();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    receive() external payable {}
}
