# Strong DAO Smart Contracts

> Production-grade, upgradeable contracts that back the BUCK savingscoin with on-chain USDC reserves and attested STRC equity. For a narrative view of the protocol, pair this README with the architecture note in `../strong-ADR/strongArch.md`.

## Key Concepts

- **BUCK vs STRC:** BUCK = on-chain ERC-20; STRC = MicroStrategy STRETCH note (brokerage custody)
- **Savingscoin:** Maintains $1.00 via overcollateralization (CR ≥ 1), absorbs STRC volatility with reserve buffers
- **CAP pricing:** $1.00 when CR ≥ 1, else max(P_STRC/100, CR) → auto-repegs when CR recovers
- **Collateral Ratio (CR):** (R + HC×V) / L where R = Reserve USDC, V = brokerage STRC value, HC = haircut (0.98), L = supply

## System Overview

- **Primary market:** Access-gated stewards mint and refund BUCK through `LiquidityWindow`, which prices against a collateral-aware peg (CAP) and enforces fee bands, per-account caps, and oracle freshness. Net USDC flows straight into the `LiquidityReserve`.
- **Treasury & solvency controls:** `PolicyManager` watches reserve ratios, attestation health, and oracle feeds. It flips the system between Green/Yellow/Red/Emergency bands, publishing spreads, fees, and mint/refund allowances that the other modules consume.
- **Collateral truth:** `CollateralAttestation` is the on-chain copy of the off-chain STRC valuation. It outputs a haircut-adjusted collateral ratio that powers CAP pricing, oracle strict-mode toggles, and governance alerts.
- **Governance token:** `BUCK` is an ERC20Permit token with upgradeable hooks. LiquidityWindow/Re­wardsEngine are the only minters, DEX transfers are tollable per band, and all balance movements stream into the rewards system.
- **Yield pass-through:** Coupon USDC is routed through `RewardsEngine`, skimmed per policy, and reminted as BUCK for holders using balance–time accounting. Anti-snipe timers and mint ceilings prevent distribution gaming.
- **Access control:** `AccessRegistry` keeps a rolling Merkle tree of approved wallets. LiquidityWindow enforces it at mint/refund time, while BUCK leaves secondary trading permissionless.
- **Price feeds:** `OracleAdapter` wraps Chainlink + Pyth with an internal price feed, letting PolicyManager demand fresh data only when the system is under-collateralized.

## User Flows

- **Approved users:** mint/refund at LiquidityWindow (gated, NAV ± spread)
- **Public users:** trade on Uniswap v2 pool (permissionless, 5bps fee each way)
- **All holders:** earn yield automatically, claim monthly (min $20)
- **DAO arb bot:** keeps DEX price near $1.00 via LiquidityWindow arbitrage

## Module Map

| Domain | Contract | Highlights |
| --- | --- | --- |
| Token | `src/token/BUCK.sol` | UUPS ERC20 with policy-driven swap fees, access-aware minting, production-mode guardrails, and a rewards hook. |
| Primary Market | `src/liquidity/LiquidityWindow.sol` | Access-gated mint/refund desk that prices via CAP, enforces spreads/fees/caps, and moves USDC into/out of the reserve. |
| Treasury Vault | `src/liquidity/LiquidityReserve.sol` | Tiered USDC vault with instant withdrawals for refunds, queued treasurer lanes, and role-based accounting. |
| Policy Plane | `src/policy/PolicyManager.sol` | Band state machine, CAP calculator, mint/refund caps, DEX fee source, and oracle strict-mode controller. |
| Collateral | `src/collateral/CollateralAttestation.sol` | Stores attested STRC value + haircuts, checks staleness, and exposes on-chain collateral ratios. |
| Rewards | `src/rewards/RewardsEngine.sol` | Balance-time accounting, coupon ingestion, distribution skim, anti-snipe enforcement, and mint throttle. |
| Compliance | `src/access/AccessRegistry.sol` | Merkle-based allowlist with attestor/owner controls and pause/revoke tooling. |
| Oracles | `src/oracle/OracleAdapter.sol` | Production oracle multiplexer with Pyth integration and internal price feed. |
| Testing | `src/mocks/*.sol` | Mock USDC and access registry to simplify local testing. |

## Contract Walkthroughs

### BUCK Token (`src/token/BUCK.sol`)

- **Role:** Canonical BUCK ERC-20. Exposes permit, pause, upgrade, and multicall surfaces while delegating minting to LiquidityWindow/RewardsEngine.
- **Key storage & structs**
  - `ModuleConfig` bundles LiquidityWindow, LiquidityReserve, treasury, PolicyManager, access registry, and rewards hook so governance can rotate dependencies atomically.
  - `feeToReservePct`, `isFeeExempt`, and `dexPair` define how swap tolls are applied and routed.
  - `productionMode` is a one-way switch that forbids clearing critical module addresses.
- **Important flows**
  - `configureModules` (owner) wires dependencies and refreshes the fee-exempt set.
  - `addDexPair`/`removeDexPair`/`setFeeSplit`/`setFeeExempt` tune DEX integrations and fee routing.
  - `mint`/`burn` are callable only by LiquidityWindow (primary market) and RewardsEngine (coupon remints); both enforce access checks on recipients.
  - `_update` overrides OZ ERC20 logic to apply PolicyManager-provided fees, push proceeds to reserve/treasury, and forward balance deltas to the rewards hook.

### LiquidityWindow (`src/liquidity/LiquidityWindow.sol`)

- **Role:** Primary market desk that swaps USDC for BUCK at NAV ± spread and honors access controls, policy bands, and reserve floors.
- **Key storage**
  - Pointers to PolicyManager/BUCK/LiquidityReserve/USDC.
  - `isLiquiditySteward` identifies bot/ops addresses that should skip fees.
  - Fee split, half-spread, and treasury sink fields mirror PolicyManager outputs but can be overridden during bring-up.
- **Important flows**
  - `configureFeeSplit`, `setAccessRegistry`, `setLiquiditySteward`, `setUSDC`, `pauseLiquidityWindow`, and `unpauseLiquidityWindow` are owner tools for runtime tuning.
  - `requestMint` batches PolicyManager's `MintParameters`, enforces access checks, price ceilings, mint caps, and slippage, then pipes net USDC to the reserve before minting BUCK.
  - `requestRefund` mirrors the mint path in reverse: checks reserve floors per band, caps refunds, burns BUCK through the token, and queues USDC withdrawals from the reserve.
  - `_routeFees`, `_calculateFloor`, and `_applySpread` are shared helpers that keep fee math centralized.

### LiquidityReserve (`src/liquidity/LiquidityReserve.sol`)

- **Role:** On-chain USDC vault that backs instant refunds and stages treasury withdrawals behind role-based delays.
- **Key data structures**
  - `TierConfig` defines three withdrawal bands (immediate/delayed/slow) as % of current balance plus a delay.
  - `WithdrawalRequest` stores queued withdrawal metadata (amount, release time, requester, tier).
- **Important flows**
  - Role-aware `recordDeposit` accepts flows from LiquidityWindow or treasurers.
  - `queueWithdrawal` auto-executes LiquidityWindow refunds or enqueues multi-hour withdrawals for treasury roles.
  - `executeWithdrawal`/`cancelWithdrawal` give treasurers + admins deterministic control over queued items.
  - `withdrawDistributionSkim` is the single path RewardsEngine uses to pull skimmed USDC for the treasury.

### PolicyManager (`src/policy/PolicyManager.sol`)

- **Role:** Control plane for spreads, fees, caps, distributions, and oracle behavior.
- **Key data structures**
  - `Band`, `BandConfig`, and `ReserveThresholds` encode the solvency state machine and its parameters.
  - `CapSettings`, `RollingCounter`, `DerivedCaps`, and `SystemSnapshot` capture aggregate mint/refund capacity and live health measurements.
  - `MintParameters` batches CAP price, spreads, fees, caps, and band info so LiquidityWindow can price in a single call.
- **Important flows**
  - `refreshBand` pulls live supply/reserve/oracle data, re-evaluates the current band, and emits `BandChanged` telemetry.
  - `getCAPPrice` fuses collateral ratios and oracle prices, enforcing attestation freshness and ensuring CAP < $1 whenever CR < 1.
  - `checkMintCap` / `checkRefundCap` / `recordMint` / `recordRefund` enforce rolling aggregate limits and per-transaction ceilings.
  - `syncOracleStrictMode` toggles the oracle adapter’s strict-mode flag when CR crosses 1.0, ensuring fresh oracles are only demanded when needed.
  - `getMintParameters` / `getRefundParameters` bundle pricing inputs for LiquidityWindow, saving ~20k gas per operation.

### CollateralAttestation (`src/collateral/CollateralAttestation.sol`)

- **Role:** Single source of truth for off-chain STRC valuations, haircuts, and freshness.
- **Key storage**
  - `V` (raw valuation), `HC` (haircut coefficient), and timestamps for both measurement and submission.
  - `healthyStaleness` / `stressedStaleness` thresholds define how often attestations must land depending on CR.
  - Contract references to BUCK, the reserve, treasury, and USDC allow live CR computation without manual snapshots.
- **Important flows**
  - `publishAttestation` (ATTESTOR_ROLE) validates staleness against the CR implied by the new data, then records valuation & haircut.
  - `getCollateralRatio` computes `(reserve + HC * V) / liabilities`, explicitly excluding treasury USDC.
  - `isAttestationStale`, `timeSinceLastAttestation`, and `isHealthyCollateral` are lightweight views consumed by PolicyManager and client dashboards.
  - Admin setters (`setContractReferences`, `setStalenessThresholds`, `setHaircut`, `setTreasury`) keep the module configurable without redeploys.

### RewardsEngine (`src/rewards/RewardsEngine.sol`)

- **Role:** Converts coupon USDC into BUCK rewards using balance-time accounting with anti-snipe protections.
- **Key data structures**
  - `AccountState` tracks each holder's balance snapshot, locked/unlocked units, reward debt, and last claim/distribution epochs.
  - Global counters (`accRewardPerUnit`, `phantomLockedUnits`, `totalLockedUnits`, `maxTokensToMintPerEpoch`) gate how fast rewards accrue and are minted.
- **Important flows**
  - `setToken` registers BUCK as the sole caller for `onBalanceChange`, ensuring every transfer updates units.
  - `onBalanceChange` (token hook) routes inflows/outflows into `_handleInflow` / `_handleOutflow`, accruing units while applying anti-snipe timing.
  - `distribute` pulls coupon USDC from the caller straight into the reserve, applies PolicyManager's distribution skim, unlocks units, and mints BUCK rewards subject to epoch caps.
  - `claim` (see contract for overloads) lets users pull unlocked BUCK once they clear `minClaimTokens` and (optionally) the one-claim-per-epoch policy.
  - Admin knobs include `configureEpoch`, `setMaxTokensToMintPerEpoch`, `setMinClaimTokens`, `setAccountExcluded`, `pauseDistribute`, and treasury/reserve hookups.

### AccessRegistry (`src/access/AccessRegistry.sol`)

- **Role:** Merkle-based allowlist enforced by LiquidityWindow at mint/refund time.
- **Key storage**
  - `merkleRoot`, `currentRootId`, and `attestor` capture the latest attestations published by the compliance service.
  - `_allowed` mapping records which wallets have successfully proven membership.
- **Important flows**
  - `setRoot` (attestor) publishes a new tree and bumps the rootId.
  - `registerWithProof` verifies Merkle proofs for end users.
  - `revoke`, `revokeBatch`, and `forceAllow` give the attestor/owner levers to keep the set accurate.
  - Pausable controls let governance halt new registrations without affecting existing allowances.

### Oracle Suite (`src/oracle/OracleAdapter.sol`)

- **Role:** Normalize external feed data for PolicyManager and LiquidityWindow.
- **Highlights**
  - Chainlink is the primary source; Pyth is an optional failover. Both outputs are scaled to 18 decimals.
  - `strictMode` is toggled directly by PolicyManager: when CR < 1.0, oracle freshness is enforced; otherwise it is ignored to save gas and handle downtimes gracefully.
  - Manual fallback pricing plus `_lastPriceUpdateBlock` let LiquidityWindow reject same-block CAP manipulations.
  - Test mocks are available in `src/mocks/` for local and testnet deployments.

### Test Support Contracts (`src/mocks/*.sol`)

- `MockUSDC.sol` and `MockAccessRegistry.sol` let the Foundry test suite simulate external dependencies without deploying the full stack.