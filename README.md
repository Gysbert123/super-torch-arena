# Super Torch Arena contract

Daily paid-entry races for Super Torch on Robinhood Chain. Entries are paid in ETH.
When a race ends, the verification server (the "settler") names the top 3 verified runners (one place per wallet) and the pool is split by percentages **fixed at deployment** (`placeBps`, `burnBps`). Suggested:

| Share | Goes to |
|---|---|
| 40% / 20% / 10% | 1st / 2nd / 3rd place (each claims with `claim()`) |
| 15% | Burn worker wallet (`withdrawBurn()`), which buys the token through KyberSwap and sends it to `0x...dEaD` |
| 15% (the rest) | Protocol treasury (`withdrawProtocol()`) |

Prizes for places nobody filled roll into the next race.

The contract doesn't need the token's address, so it can be deployed before the token launches.

## How a day works

1. **Before the race** (recommended): the settler calls `commitSeeds(raceId, hash)` to commit to that day's run seeds.
2. **During the race**: players call `enter()` with exactly `entryFee` wei. The returned `entryId` is what the server uses to hand out that run's seed.
3. **After the race ends** (00:00 UTC by default): the settler calls `settle(raceId, [1st, 2nd, 3rd], [scores], runHash)`, using `address(0)` for empty places.
   - `runHash` = hash of the winning run's seed + input log, so anyone can replay it.
   - No 1st place (`address(0)`) means no verified run: the whole pool rolls into the current race.
4. **Burn**: anyone can call `withdrawBurn()`; the burn share always goes to `burnWallet`. The server's burn worker then swaps it for the token and sends the tokens to the dead address. `totalSentToBurn` (read by the website) counts every wei sent to the worker.
5. **Payouts**: the winner calls `claim()`. Anyone can call `withdrawProtocol()`, which always pays the treasury.

## Player protections

- **Refunds**: if a race isn't settled within 3 days of ending, settlement is locked and every entrant can call `refund(raceId)` to get exactly what they paid back.
- **Abandoned funds are burned, not taken**: 30 days after the refund window opens, anyone can call `sweepExpired(raceId)`; whatever is left goes to the burn share, never to the operator.
- **The owner cannot touch the pool**: there is no admin withdraw. The owner can only change the entry fee, settler, treasury and burn wallet, and pause new entries. Use a multisig (e.g. Safe) as the owner.
- **Pull payments**: a winner whose wallet rejects ETH can't block anyone else.

## Build, test, deploy

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
forge test

export OWNER=0x... SETTLER=0x... TREASURY=0x... BURN_WALLET=0x... ENTRY_FEE_WEI=1000000000000000
# optional, defaults shown: FIRST_BPS=4000 SECOND_BPS=2000 THIRD_BPS=1000 BURN_BPS=1500
forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast --private-key $DEPLOYER_KEY
```

Or deploy from the browser with Remix (see the Railway guide). After deploying, set `arenaAddress` in the website's `CONFIG`.

## Before mainnet

- Get the contract **audited**. It holds other people's money.
- Owner = **multisig**, settler and burn worker = separate server wallets holding only gas money.
- Get **legal advice** on running paid-entry prize competitions where you and your players are.
