# ServiceRegistry

An onchain service registry for agent infrastructure — built for [The Synthesis hackathon](https://synthesis.md).

Services stake ETH to get listed. Agents rate them. Bad services get slashed. The market self-cleans.

**Live on Base mainnet:**
- V1: [`0xc6922DD8681B3d57A2955a5951E649EF38Ea1192`](https://basescan.org/address/0xc6922DD8681B3d57A2955a5951E649EF38Ea1192)
- V2: [`0x...`](https://basescan.org/address/0x...) _(pending deployment — see V2 section)_

---

## Architecture

```
ServiceRegistryV2
├── Registration    — stake ETH, publish capabilitiesURI, choose category
├── Reputation      — agents rate 1-5, good/bad scores shift 0-10000 score
├── Slashing        — too many bad ratings → 20% stake slashed → deactivation
├── Online Status   — heartbeat()/isOnline() TTL-based liveness signal (V2)
├── Skill Tags      — bytes32 tags (keccak256 labels, max 8 per service) (V2)
├── Job Tracking    — ACH/owner records completions, uniqueBuyers tracked (V2)
└── Grad Tiers      — Bronze/Silver/Gold/Platinum computed from jobs+rep (V2)
```

---

## V1 Features

| Feature | Description |
|---------|-------------|
| `register()` | Stake ≥ 0.001 ETH, publish capabilitiesURI JSON |
| `rateService()` | Score 1-5, rate limited 1/day/agent/service |
| `slashService()` | 20% stake slash per incident; auto-triggered at 10 bad ratings |
| `withdrawAndExit()` | Withdraw stake, deactivate service |
| `getServicesByCategory()` | Filter active services by category with pagination |
| `updateCapabilities()` | Update capabilities URI and price |

---

## V2 Features

V2 (`ServiceRegistryV2.sol`) extends V1 with four new capability layers inspired by [Virtual Protocol's ACP](https://docs.virtualprotocol.io/acp) graduation framework.

### 1. Online Status

Services can signal liveness with a heartbeat. A service is considered "online" if it heartbeated within the last **5 minutes**.

```solidity
// Signal online
registry.heartbeat(serviceId);

// Check liveness (respects 5-min TTL)
bool alive = registry.isOnline(serviceId);

// Explicit offline
registry.setOffline(serviceId);
```

Events: `Heartbeat(uint256 indexed id)`

### 2. Skill Tags

Up to **8 skill tags** per service using `bytes32` hashes (e.g. `keccak256("llm")`, `keccak256("price-feed")`). Enables efficient onchain discovery.

```solidity
// Set tags (owner only, max 8)
bytes32[] memory tags = new bytes32[](2);
tags[0] = keccak256("llm");
tags[1] = keccak256("price-feed");
registry.setTags(serviceId, tags);

// Query
bool hasLLM = registry.hasTag(serviceId, keccak256("llm"));
uint256[] memory llmServices = registry.getServicesByTag(keccak256("llm"), 20);
```

Events: `TagsUpdated(uint256 indexed id)`

### 3. Job Completion Tracking

The AgentCommerceHub (ACH) or service owner can record completed jobs. Tracks `successfulJobs` and `uniqueBuyers` — the raw inputs for graduation tiers.

```solidity
// Called by ACH (0x0667988FeaceC78Ac397878758AE13f515303972) or service owner
registry.recordJobCompletion(serviceId, buyerAddress);

// Check if a buyer has transacted with a service
bool returning = registry.hasBought(serviceId, buyer);
```

ACH address: `0x0667988FeaceC78Ac397878758AE13f515303972`

Events: `JobCompleted(uint256 indexed id, address buyer)`

### 4. Graduation Tiers

Tiers are **computed views** — not stored. They update dynamically as jobs and reputation change.

| Tier | successfulJobs | reputationScore |
|------|---------------|-----------------|
| Bronze | ≥ 1 | ≥ 4000 |
| Silver | ≥ 5 | ≥ 5000 |
| Gold | ≥ 20 | ≥ 7000 |
| Platinum | ≥ 50 | ≥ 9000 |

```solidity
ServiceRegistryV2.Tier tier = registry.getTier(serviceId);
// Tier.None, Tier.Bronze, Tier.Silver, Tier.Gold, Tier.Platinum
```

Events: `TierUpgraded(uint256 indexed id, Tier tier)`

### 5. Discovery Helpers

```solidity
// Services with a specific tag (active only)
uint256[] memory llm = registry.getServicesByTag(keccak256("llm"), 50);

// Top N by reputation (insertion sort, suitable for < 500 services)
uint256[] memory top10 = registry.getTopByReputation(10);

// Currently online (heartbeat within 5 min)
uint256[] memory online = registry.getOnlineServices(20);
```

---

## Test Coverage

```
Ran 40 tests for ServiceRegistryV2Test — 40 passed, 0 failed
Ran 14 tests for ServiceRegistryTest (V1 compat) — 14 passed, 0 failed
Total: 54 tests, 0 failures
```

Key test categories:
- V1 compatibility (14 tests — all V1 behaviour preserved)
- Online status (heartbeat, expiry, setOffline, ownership)
- Skill tags (set, replace, max 8, hasTag, getServicesByTag)
- Job completion (ACH, owner, unique buyers, authorization)
- Graduation tiers (Bronze → Platinum, rep threshold enforcement)
- Discovery helpers (getTopByReputation, getOnlineServices, limits)
- Fuzz tests (reputation bounds, tier monotonicity)

---

## Deploy

```bash
export PATH="$PATH:/home/openclaw/.foundry/bin"

# Build
cd service-registry && forge build

# Get bytecode and ABI-encode constructor arg
OWNER_ARG=$(cast abi-encode "constructor(address)" <owner_address> | sed 's/0x//')
BYTECODE=$(forge inspect ServiceRegistryV2 bytecode)
DEPLOY_DATA="${BYTECODE}${OWNER_ARG}"

# Estimate gas (add 20% buffer)
cast estimate --rpc-url https://mainnet.base.org --from <deployer> --create "${DEPLOY_DATA}"

# Deploy
cast send \
  --rpc-url https://mainnet.base.org \
  --private-key <deploy_key> \
  --gas-limit <estimate_with_buffer> \
  --create "${DEPLOY_DATA}"
```

---

## Foundry Quick Reference

```bash
forge build          # compile
forge test           # all tests
forge test -vvv      # verbose
forge inspect ServiceRegistryV2 abi  # ABI
cast call <addr> "isOnline(uint256)" 0 --rpc-url https://mainnet.base.org
```
