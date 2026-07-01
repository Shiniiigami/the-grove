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

### Known follow-ups (not yet applied)

- A passing offering that hits the "Eye is full" (3 offered) cap at apply time is
  consumed with no effect (no +150 / robe / +50). Rare but reachable; needs a
  product decision on desired behaviour.
- The remaining `grove_*` RMW functions (`grove_action`, `grove_save`,
  `grove_chalice`, `grove_wheel`, …) should also take `FOR UPDATE`.
