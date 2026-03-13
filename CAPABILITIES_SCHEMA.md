# Service Capabilities Schema

Every service registered in ServiceRegistry MUST expose a capabilities manifest at its `capabilitiesURI`.
This is the machine-readable contract between a service and the agents that consume it.

## Schema

```json
{
  "$schema": "https://deluagent.github.io/service-registry/capabilities-schema.json",
  "name": "string — service display name",
  "description": "string — what the service does",
  "version": "string — semver",

  "onchain": {
    "serviceRegistryId": "uint — id in ServiceRegistry contract",
    "contract": "0x... — Base mainnet contract address (if applicable)",
    "chain": "base",
    "chainId": 8453
  },

  "payment": {
    "standard": "x402 | erc-8183 | free",
    "pricePerCall": "$0.001 USDC",
    "token": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "receiver": "0x... — address that receives payment",
    "network": "eip155:8453"
  },

  "category": "AI | Data | Identity | Infrastructure | Coordination | Other",

  "endpoints": [
    {
      "path": "/v1/chat/completions",
      "method": "POST",
      "description": "string",
      "payment": "x402 | free",
      "price": "$0.001",
      "input": { "model": "string", "messages": "array" },
      "output": { "choices": "array" }
    }
  ],

  "health": "/health",
  "capabilities": "/.well-known/capabilities",

  "sla": {
    "uptimePct": 99.9,
    "maxLatencyMs": 2000,
    "dataRetention": "none | 24h | 7d | indefinite"
  },

  "agent": {
    "erc8004Id": "uint — agent id in ERC-8004 registry (if agent-operated)",
    "identity": "eip155:8453:0x8004...:30004"
  }
}
```

## Required fields

- `name`, `description`, `version`
- `onchain.serviceRegistryId`
- `payment.standard`
- `endpoints` (at least one)
- `health`

## Categories

| ID | Name | Description |
|----|------|-------------|
| 0 | AI | LLM inference, embeddings, image gen |
| 1 | Infrastructure | RPC, indexing, storage, compute |
| 2 | Data | Price feeds, oracles, analytics |
| 3 | Coordination | Scheduling, routing, orchestration |
| 4 | Identity | Reputation, attestations, credentials |
| 5 | Other | Everything else |

## Payment standards

| Standard | Use case |
|----------|----------|
| `x402` | Per-call micropayments ($0.001–$1.00). HTTP 402 + EIP-3009 USDC. |
| `erc-8183` | Multi-step jobs with escrow + evaluator attestation. |
| `free` | Public endpoint, no payment required. |

## Discovery

Agents SHOULD:
1. Query ServiceRegistry `/services` sorted by `reputationScore` descending
2. Filter by `category` matching their need
3. Fetch `capabilitiesURI` to read input/output schema
4. Pick highest-reputation service that accepts their payment method
5. Submit `rateService()` after each call with honest score (1–5)
