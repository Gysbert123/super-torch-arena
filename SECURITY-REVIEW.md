# Automated security review (Slither 0.11.6)

Scope: `src/SuperTorchArena.sol`. Dependencies, tests and scripts excluded.
Slither ran 102 detectors: 8 results, all reviewed below. This is a free automated scan, **not a replacement for a manual audit**. Give this file to your auditor; it saves them time.

## Fixed after earlier scans

| Finding | Fix |
|---|---|
| unindexed-event-address | Address parameters in admin events are indexed |
| Buyback adapter findings (unchecked WETH transfer, zero checks, reentrancy notes) | The on-chain buyback adapter was removed. Burns now go to a burn worker wallet, so this code no longer exists |

## Reviewed and accepted (by design)

| Finding | Why it's acceptable |
|---|---|
| **arbitrary-send-eth** in `_send` | ETH only goes to `msg.sender` (their own `claim` / `refund` balance), to `treasury`, or to `burnWallet`; both addresses can only be set by the owner. |
| **incorrect-equality** (`raceId == currentRace()`) | Exact comparison is intended and can't be used to bypass a check. |
| **cyclomatic-complexity** in `settle` | Expected: it validates up to 3 winners (entered, distinct, filled in order) and computes each share. Fully covered by tests (`test_PodiumSplit`, `test_TwoPlacesFilled`, `test_PodiumRules`, fuzzed solvency). |
| **timestamp** | Races are daily; validators' few-seconds timestamp influence has no meaningful effect. |
| **low-level-calls** in `_send` | Required to send ETH; the result is checked, and every caller is `nonReentrant` with state updated first. |

## Trust assumptions an auditor should check

1. **Owner (use a multisig):** can change the entry fee, settler, treasury and burn wallet, and pause entries. Cannot withdraw pool funds.
2. **Settler (server hot wallet):** chooses each race's winner. Players rely on the published replays (`/api/run/<entryId>`) and seed commitments to verify it was honest. If the settler disappears, players can refund after 3 days.
3. **Burn worker (server hot wallet):** receives 25% of each pool and is trusted to swap it and send the tokens to the dead address. Every burn is a public transaction listed on the website, and the contract's `totalSentToBurn` lets anyone compare ETH received against tokens burned.

## Not run here

Aderyn could not download a compiler in this environment. Run it locally: `npx @cyfrin/aderyn . --src src`.
