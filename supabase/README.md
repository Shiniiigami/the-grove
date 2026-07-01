# Supabase — The Grove

The Grove is a static PWA (`index.html` + `sw.js`) backed by a single Supabase
project (`drthfetglhqfgqxcrngr`, "The Grove"). All shared state lives in one row
of `public.grove_state` (`id = 1`, a `jsonb` blob) and is mutated exclusively
through `SECURITY DEFINER` RPCs (`grove_action`, `grove_propose`, `grove_vote`,
`grove_wheel`, `grove_chalice`, `grove_seed`, `grove_save`, …). The server is the
authoritative, anti-cheat copy of the game logic that `index.html` mirrors
client-side for its offline queue.

`public.grove_ver()` returns the schema stamp the client checks against
`EXPECTED_DB` in `index.html`; bump both together when server behaviour the
client relies on changes.

## migrations/

Provenance copies of the migrations applied to the remote project (names and
timestamps match the Supabase migration history). They are recorded here for
review — the remote is the source of truth and already has them applied.

The `2026-07-01a` set brought the server into parity with the client's reworked
offering rules and passing-rite nominator rewards:

- `grove_propose` — global 6h public offering cooldown, 30-minute nomination
  window, 24h per-target cooldown, and a block on offering an already-offered
  spirit (per-supplicant 12h cooldown and the 3-offered cap retained; the
  Keeper's `offerGateClearedAt` bypasses the public cooldown).
- `grove_vote` — nominator bounties for passing titles (+25), badges (+20) and
  deeds (+5..+30 by size); offerings robe the offered for 3h and pay their
  nominator +50 (the offered still gain +150).

The `2026-07-01b` set is hardening surfaced by adversarial testing:

- `grove_propose` — rejects rites whose `target` is not a real spirit (every
  kind except `newdeed`, which has no target); previously only the nominator was
  validated, so phantom rites could be raised against non-members.
- `grove_propose` + `grove_vote` — `SELECT ... FOR UPDATE` on the single
  `grove_state` row so concurrent proposals/votes serialise instead of clobbering
  the shared blob. (Other `grove_*` writers still need the same treatment for
  full coverage — a recommended follow-up.)
- `grove_ver` — stamped `2026-07-01b`.

The `2026-07-01c` set fixes two anomalies surfaced by the lifecycle audit:

- `grove_action` — a matched wager left in dispute past the 1h window used to go
  `forfeit` and **burn both stakes** (a silent points sink). It now refunds both
  and settles as a tie, matching the group-wager `void` path.
- `grove_action` — the fire **stoke cooldown** was 6h server-side but 3h in the
  client, so a stoke between 3h and 6h passed on the client then got silently
  reverted ("the log didn't count"). Server aligned to 3h.
- `grove_ver` — stamped `2026-07-01c`.

The client build carries matching UX: `flushQueue` now toasts when a queued
offline action is dropped/rejected ("… couldn't apply — the grove had moved on")
and summarises "synced N · M couldn't apply"; live-state settlement actions
(wager/challenge/group interactions) are gated offline instead of queuing doomed
replays; and the dispute-timeout wording says the pot is returned.

The `2026-07-01d` set:

- Reverted the wager dispute-timeout to **forfeit** (both stakes burned), by
  request — not a refund.
- Aligned the client fire **decay** to 3h (`sweepFire`); the server already
  decayed 1 log per 3h but the client used 2h, so the fire looked lower
  client-side between refreshes.
- **Blessing scope:** the ×2/×3 wheel blessing (`winMult`) now also multiplies
  the next positive community deed, Devotion wheel spin, Chalice total, and
  normal (non-group) wager win, then is consumed. Wager blessing multiplies the
  net winnings (winner gets stake back + M×stake). Applied in `grove_vote`,
  `grove_wheel`, `grove_chalice`, `grove_action`, mirrored in the client.
- `grove_ver` → `2026-07-01d`.

Both layers were fuzz-checked: the client model over 25×2 runs of 3-simulated-day
heavy activity, and the server over 600 randomised actions with forced
sweeps/forfeits — point conservation (`members + locked-in-bets + burned == start`)
held at every step, with no negatives or crashes on fuzzed names/notes/amounts.

The `2026-07-01e` set is the fixes from a five-agent audit:

- **grove_chalice** — clamp the client-supplied commit `delta` to ±500. Previously
  uncapped: an anon caller could `grove_chalice({commit:[{name,delta:999999}]})` and
  set any spirit to any value (unlimited point minting). Now bounded to a real
  game's range.
- **FOR UPDATE** rolled out to `grove_action`, `grove_chalice`, `grove_withdraw`,
  `grove_set_chibi`, `grove_clear_rites` — closes the lost-update race for the
  read-modify-write RPCs (propose/vote already had it).
- **grove_wheel** now writes the Test-of-Devotion tally (`devotion.{spins,total}`)
  server-side, so it persists in hosted play instead of only existing on the
  device that spun.
- **grove_save** optimistic concurrency: rejects a stale full-blob save (a keeper
  saving an out-of-date snapshot could otherwise revert everyone's concurrent
  activity). Client threads `updated_at` through `sbRead`→`grove_save`.
- **Self-nomination**: allowed for deeds (you get the deed points, not the
  nominator bounty) and oaths (self by design); blocked for title/badge/offer,
  server-side and in the nomination forms.

### Known follow-ups (not yet applied)

- A passing offering that hits the "Eye is full" (3 offered) cap at apply time is
  consumed with no effect (no +150 / robe / +50). Rare but reachable; needs a
  product decision on desired behaviour.
- The `chal_approve` maxed-trial cheat guard is a hard cliff at reward ≥150; a
  reward-149 challenge + ×3 buff pays ~+447 with no penalty (agent finding).
- `grove_chalice` still trusts the client for `drained` (a free "Drained the
  Chalice" badge) and the game state blob generally; the ±500 delta clamp bounds
  the point impact but the chalice remains a client-refereed mini-game.
- Latent: `grove_action`'s fire-goal default is 8 while the client's is 6 (live
  `fire.goal` is 6, only matters on a fresh reseed).
- `grove_action.wheel_spin` is dead (remote clients use `grove_wheel`) and still
  charges 50 vs the live 15 — safe to remove.
