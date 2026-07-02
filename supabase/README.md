# The Grove — Supabase backend

The Grove is a single-file PWA (`../index.html`). When `SUPABASE.url` + `anonKey`
are set (they are), it runs in **remote mode**: state lives in one Supabase row
and every write goes through a `grove_*` RPC so the grove is live across phones
with Keeper-only privileged actions.

## Files

- **`schema.sql`** — the canonical, idempotent source of truth: tables, the one
  public-read RLS policy, every `grove_*` function, and the anon/authenticated
  grants. Running it whole brings a project fully up to date. Older on-screen
  messages in the app refer to `grove_trials.sql` / `grove_thought.sql`; those
  were fragments — this single file supersedes them.
- **`migrations/`** — dated records of individual changes, newest = current DB
  version reported by `grove_ver()`.

## Applying

Web/remote (no CLI): run `schema.sql` in the Supabase SQL editor, or apply the
changed functions via the MCP `apply_migration` tool. The client gates on
`grove_ver()` ≥ `EXPECTED_DB` (`index.html`), so keep `grove_ver()` current.

## Design / security notes

The app is a public **honour-system** game. The `anon` key calls the
`SECURITY DEFINER` RPCs directly; this is intentional:

- `grove_state` is publicly **readable** (one `SELECT` policy) so any device can
  hydrate the shared blob.
- `grove_config` (holds the **bcrypt-hashed** keeper passphrase) and
  `grove_push_subs` have RLS enabled with **no policy** — reachable only through
  the definer functions, never by direct REST.
- Keeper-only mutations (`grove_save`, `grove_setpass`, `grove_clear_rites`,
  `grove_remove_rite`) verify the passphrase *inside* the function.
- Point-moving RPCs are **server-canonical**: they clamp values, enforce
  cooldowns/thresholds, and never trust client-supplied points.

Because of the above, the Supabase linter's `rls_enabled_no_policy` (INFO) and
`anon/authenticated_security_definer_function_executable` (WARN) notices are
**expected** for this architecture, not defects — revoking anon EXECUTE would
break the app.

## Current server version

`grove_ver()` → `2026-07-02a`
