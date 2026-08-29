# CLAUDE.md — FreeWhen

An ephemeral meeting scheduler. Attendees mark when they are **free**, the
server intersects the answers in RAM and publishes counts — never who is free
when. No database, no accounts, no calendar integration, and nothing about a
person beyond an alias they chose.

Read `docs/ARCHITECTURE.md` for the layer map, the supervision tree and the
decisions behind both; `docs/DEVELOPING.md` for the local loop; `docs/PLAN.md`
for what is left. Change a decision and its entry in ARCHITECTURE in the same
commit.

## Commands

- `rebar3 do compile, eunit, ct, xref, dialyzer` — what CI runs
- `rebar3 shell` — boots `fw_web` on http://localhost:8080
- `cd web && npm run watch` — rebuild the client on save
- `cd web && npm run check && npm test` — strict `tsc`, then `node --test`
- `rebar3 as prod tar` — the release tarball; **must be built on Ubuntu 24.04**
- `ansible-playbook -i deploy/inventory.ini deploy/site.yml` — provision and deploy

Warnings are errors. `dialyzer` and `xref` must be clean, and no `nowarn`
without a comment saying why.

## The three layers

Dependencies point one way. A module may only call *downward*.

| app | may depend on | must never mention |
|---|---|---|
| `fw_core` | stdlib, `crypto` | processes, JSON, cowboy, `application:get_env` |
| `fw_runtime` | `fw_core` | JSON, cowboy, HTTP concepts |
| `fw_web` | both | — |

The directory says what a module *is*:

```
fw_core/src/domain/      the aggregate and its value objects
fw_runtime/src/ports/    behaviours the runtime needs satisfied
fw_runtime/src/rooms/    rooms as processes, and how they are addressed
fw_runtime/src/support/  clock, ids, settings, rate limiting
fw_web/src/http/         cowboy handlers
fw_web/src/ws/           the websocket
fw_web/src/json/         the protocol, in one place
```

`fw_core` is pure: same input, same output, no clock, no randomness, no
processes, no config lookups. Time and entropy arrive as arguments from the
layer above. This is the single most important rule here.

**The server decides; the browser formats.** Every domain fact is computed in
`fw_core` and published whole. Computing something in TypeScript that the
server could have answered is the bug.

The client is TypeScript with Lit templates in `web/`, built to
`apps/fw_web/priv/static`. Everything but `main.ts` is a pure function;
`main.ts` owns the state and every side effect.

## Hard rules

- **One thing is persisted, behind one port.** Rooms are snapshotted through
  `fw_room_snapshots`. That is the only thing that touches a disk, it is off by
  default, and nothing else may write anywhere. Never log a room hash, alias,
  availability or host token.
- **Every export has a `-spec`.** `warn_missing_spec` is on. Types crossing a
  module boundary are declared; aggregate and value types are `-opaque` with
  accessors.
- **200 lines per module, 30 per function**, enforced by
  `.claude/hooks/check_erl.escript`. Hitting the limit is a design signal:
  split by responsibility, never by line count.
- **Keep it small.** Before adding a module, an abstraction or a dependency,
  check that a requirement actually needs it. Nothing here is built for a scale
  it does not have.
- **No `catch`-all clauses.** Match the shapes you expect; let an unexpected
  shape crash the room process. One room crashing never affects another, and
  that isolation is why it is safe to be strict.
- **User input is untrusted data, never atoms.** `binary_to_atom` on anything
  that arrived over a socket is a memory-exhaustion bug.
- **`crypto:strong_rand_bytes/1` for every identifier** a client could
  otherwise guess. Compare secrets with `crypto:hash_equals/2` after a length
  check. A room hash is the SHA-256 of its host token, and that derivation is
  what makes a room resumable — do not change it to a fresh random value.
- **Two ports, on purpose.** `fw_room_store` and `fw_room_snapshots`.
  Everything else the domain needs arrives as a value; a behaviour with one
  implementation and no prospect of a second is ceremony.
- **The server holds no timezone.** Every instant is UTC; each browser
  canonicalises against its own locale. There is no field for a location and
  there should not be one.

## Conventions

- Comments state what the code cannot: an invariant, its reason, why a slow
  path is acceptable. No narration, no history.
- Every module is prefixed `fw_` and named for what it owns, singular.
- Tagged tuples for messages and commands, maps for aggregates and config,
  records only inside a single module.
- Ports are `-callback` behaviours; adapters are named for the technology they
  adapt. A behaviour past five callbacks is two ports.
- Errors are `{error, Reason}` with an atom or tagged tuple. Strings are for
  humans at the edge, and the edge is `fw_web`.

## Writing tests

Unit-test the pure modules exhaustively — they have no setup, so there is no
excuse. `rebar3 ct` covers the process and socket layers; `npm test` covers the
client's pure modules and its reconnection state machine. Test names read as
sentences about behaviour. Assert exact values, not `>= 0`. See
`.claude/skills/testing-discipline/SKILL.md`.
