// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ServiceRegistry
/// @notice A service registry where agents discover, evaluate, and route to the
///         best services — and where services have skin in the game.
///
/// @dev Core mechanic:
///   1. Services stake ETH to register. Stake = skin in the game.
///   2. Agents call services and rate them onchain (1-5 stars).
///   3. Bad ratings → reputation drops. Enough disputes → stake slashed.
///   4. Good services rise. Bad services get penalised or exit.
///   5. No curator. No platform. The market self-cleans.
///
/// @dev Service discovery:
///   - Services publish a `capabilitiesURI` (JSON manifest: what it does, price, endpoint)
///   - Agents filter by category, minReputation, maxPricePerCall
///   - Agents route to highest reputation service in their budget
///
/// @dev Dispute flow:
///   - Agent calls `rateService(id, score, evidenceURI)`
///   - score < 3 = negative rating, increments `badResponses`
///   - Owner can slash if badResponses exceeds threshold
///   - Slashed stake → protocol treasury (used for rewards / insurance)
///
/// @dev x402 compatibility:
///   - `pricePerCallWei` is the on-chain price. Services return HTTP 402 with this amount.
///   - Agents read this field to know what to pay before calling.

contract ServiceRegistry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant MIN_STAKE            = 0.001 ether;
    uint256 public constant SLASH_BPS            = 2000;   // 20% slash per incident
    uint256 public constant REGISTRATION_FEE_BPS = 500;    // 5% of stake → protocol treasury
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1000;   // 10% max (governance bound)
    uint256 public constant BAD_RESPONSE_THRESHOLD = 10; // slash after 10 bad ratings
    uint256 public constant REPUTATION_START = 5000;   // 50/100
    uint256 public constant REPUTATION_MAX   = 10000;
    uint256 public constant REPUTATION_GOOD  = 100;    // +1% per good rating
    uint256 public constant REPUTATION_BAD   = 500;    // -5% per bad rating

    // ─── Types ────────────────────────────────────────────────────────────────
    enum Category {
        Data,        // data feeds, APIs
        Compute,     // inference, processing
        Storage,     // IPFS, Filecoin, Arweave
        Oracle,      // price feeds, external data
        Identity,    // auth, credentials
        Other
    }

    struct Service {
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

    // ─── Events ───────────────────────────────────────────────────────────────
    event ServiceRegistered(uint256 indexed id, address indexed owner, string name, Category category);
    event ServiceUpdated(uint256 indexed id, string capabilitiesURI, uint256 pricePerCallWei);
    event ServiceRated(uint256 indexed id, address indexed rater, uint8 score, string evidenceURI);
    event ServiceSlashed(uint256 indexed id, uint256 slashAmount);
    event ServiceDeactivated(uint256 indexed id);
    event StakeIncreased(uint256 indexed id, uint256 amount);
    event StakeWithdrawn(uint256 indexed id, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error InsufficientStake(uint256 provided, uint256 required);
    error NotServiceOwner();
    error ServiceNotActive();
    error ServiceSlashedError();
    error InvalidScore();
    error RatingTooSoon(uint256 nextAllowed);
    error NotFound();
    error CannotRateOwn();

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
        services[id] = Service({
            owner:            msg.sender,
            name:             name,
            capabilitiesURI:  capabilitiesURI,
            pricePerCallWei:  pricePerCallWei,
            category:         category,
            stakedETH:        stakedAmount,
            reputationScore:  REPUTATION_START,
            totalCalls:       0,
            goodResponses:    0,
            badResponses:     0,
            registeredAt:     block.timestamp,
            active:           true,
            slashed:          false
        });
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
    ///         Bad score (<=2) = negative rating. Good score (>=4) = positive.
    function rateService(
        uint256 id,
        uint8 score,
        string calldata evidenceURI
    ) external {
        if (score == 0 || score > 5) revert InvalidScore();

        Service storage svc = services[id];
        if (!svc.active) revert ServiceNotActive();
        if (svc.owner == msg.sender) revert CannotRateOwn();

        // Rate limit: once per 24h per agent per service (skip if never rated)
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
            // Good response
            svc.goodResponses++;
            svc.reputationScore = _min(
                svc.reputationScore + REPUTATION_GOOD,
                REPUTATION_MAX
            );
        } else if (score <= 2) {
            // Bad response
            svc.badResponses++;
            svc.reputationScore = svc.reputationScore > REPUTATION_BAD
                ? svc.reputationScore - REPUTATION_BAD
                : 0;

            // Auto-slash if threshold exceeded
            if (svc.badResponses % BAD_RESPONSE_THRESHOLD == 0) {
                _slash(id, svc);
            }
        }
        // score == 3 = neutral, no reputation change

        emit ServiceRated(id, msg.sender, score, evidenceURI);
    }

    // ─── Slash ────────────────────────────────────────────────────────────────

    /// @notice Owner can manually slash a service for provably bad behaviour.
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

        // Deactivate if stake drops below minimum
        if (svc.stakedETH < MIN_STAKE) {
            svc.active = false;
            emit ServiceDeactivated(id);
        }

        emit ServiceSlashed(id, slashAmount);
    }

    // ─── Withdraw / Exit ──────────────────────────────────────────────────────

    /// @notice Service owner withdraws stake and exits registry.
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

    // ─── Discovery ────────────────────────────────────────────────────────────

    /// @notice Get services by category, ordered externally by reputation.
    ///         Returns up to `limit` active service IDs.
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

    /// @notice Get a service's full profile.
    function getService(uint256 id) external view returns (Service memory) {
        if (id >= serviceCount) revert NotFound();
        return services[id];
    }

    /// @notice Get all ratings for a service.
    function getRatings(uint256 id) external view returns (Rating[] memory) {
        return serviceRatings[id];
    }

    /// @notice Get services owned by an address.
    function getOwnerServices(address owner) external view returns (uint256[] memory) {
        return ownerServices[owner];
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
