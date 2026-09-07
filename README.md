# HashBox

Timed prize-pool. Connect or generate a wallet, then **Start Box** (operator) or **Live Box** (join open campaigns).

## Initialize

- **Connect wallet** — injected `window.ethereum`
- **Generate wallet** — demo 0x identity (not a funded key)

## Start Box (operator)

- Minimum entrance
- Cycle: **1 min / 1 hour / 24 hours**
- Number of cycles (1–30). For 24h this is "# of 24 hour cycles"
- Enrollment time — window **before** the locked phase
- Timeline: ENROLL → LOCK → DRAW (one draw after the full lock)

`lockEnd = now + enrollSeconds + cycleSeconds * cycleCount`

## Live Box

- **Open Hashbox** — enrollment live, wallets can join
- **Closed Hashbox** — already in progress, roster visible, no new stakes
- Live Hashbox list = enrolled users (address, ticket, stake)

## Run the demo

```bash
python3 -m http.server 8765 --directory frontend
# http://localhost:8765
```

Repo: https://github.com/vaporwavelabs/hashbox
Contract: `contracts/HashBox.sol`

Winner-takes-all. A miss keeps the pot locked for the next campaign. Not yield staking. No mainnet without audit and counsel.
