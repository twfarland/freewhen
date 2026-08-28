# CLAUDE.md — FreeWhen

An ephemeral meeting scheduler. Attendees mark when they are busy, and the
server intersects everyone's answers in RAM and publishes counts — never who is
free when. No database, no accounts, no calendar integration, and nothing about
a person beyond an alias they chose.

Read `docs/ARCHITECTURE.md` for the layer map and `docs/PLAN.md` for what is
built and what is next. Decisions live in `docs/adr/` — change one only by
adding an ADR that supersedes it.

## Commands

- `rebar3 compile` — strict build; warnings are errors
- `rebar3 eunit` — unit tests (the pure modules)
- `rebar3 ct` — integration tests (real cowboy, real sockets)
- `rebar3 dialyzer` — must be clean; no `nowarn` without a comment saying why
- `rebar3 xref` — no undefined calls, no unused locals
- `rebar3 do compile, eunit, ct, dialyzer, xref` — what CI runs
- `rebar3 shell` — boots `fw_web` on http://localhost:8080
- `cd web && npm run build` — bundles the client into `apps/fw_web/priv/static`
- `cd web && npm run check` — strict `tsc`, no emit

## The three layers

Dependencies point one way. A module may only call *downward*.

| app | may depend on | must never mention |
|---|---|---|
| `fw_core` | stdlib only | processes, JSON, cowboy, `application:get_env` |
| `fw_runtime` | `fw_core` | JSON, cowboy, HTTP concepts |
| `fw_web` | both | — |

Modules are grouped by role inside each app, and the directory says what a
module is:

```
fw_core/src/domain/      the aggregate and its value objects
fw_runtime/src/ports/    behaviours the runtime needs satisfied
fw_runtime/src/rooms/    rooms as processes, and how they are addressed
fw_runtime/src/support/  clock, ids, settings, rate limiting
fw_web/src/http/         cowboy handlers
fw_web/src/ws/           the websocket
fw_web/src/json/         the protocol, in one place
```

`fw_core` is the domain. It is pure: same input, same output, no clock, no
randomness, no processes, no config lookups. Time and entropy arrive as
arguments from the layer above. This is what makes the domain tests
deterministic and fast, and it is the single most important rule here.

**The server decides; the browser formats.** Every domain fact — the heatmap,
the ranked proposals with their UTC instants, who has answered, whether the
room is settled — is computed in `fw_core` and published whole. The client
turns instants into words in a timezone and does no arithmetic beyond laying
the grid out into local days. If you find yourself computing something in
TypeScript that the server could have answered, that is the bug
(`docs/adr/0009`).

The browser client is TypeScript with Lit templates, in `web/`, built to
`apps/fw_web/priv/static`. `view.ts` and `grid.ts` are pure functions from
state to a template; `main.ts` owns the state and every side effect. There is
no calendar integration anywhere, by decision (`docs/adr/0006`).

## Hard rules

- **One thing is persisted, behind one port.** Rooms are snapshotted through
  `fw_room_snapshots` so a release does not cost them (`docs/adr/0011`). That
  is the only thing that touches a disk, it is off by default, and nothing else
  may write anywhere. Never log a room hash, alias, availability or host token.
- **Every export has a `-spec`.** `warn_missing_spec` is on and warnings are
  errors, so the compiler enforces it. Types that cross a module boundary are
  declared, and aggregate/value types are `-opaque` with accessors.
- **200 lines per module, 30 per function**, enforced by
  `.claude/hooks/check_erl.escript`. Hitting the limit is a design signal, not
  a formatting problem: split by responsibility, never by line count.
- **Keep it small.** This whole system is a few hundred lines of Erlang. Before
  adding a module, an abstraction, or a dependency, check that a requirement
  actually needs it. Nothing here is built for a scale it does not have.
- **No `catch`-all clauses.** Match the shapes you expect; let an unexpected
  shape crash the room process. One room crashing must never affect another,
  and that isolation is the reason it is safe to be strict.
- **User input is untrusted data, never atoms.** `binary_to_atom` on anything
  that reached us over a socket is a memory-exhaustion bug.
- **`crypto:strong_rand_bytes/1` for every identifier** a client could
  otherwise guess: host tokens and attendee ids. Compare secrets with
  `crypto:hash_equals/2`. A room hash is the SHA-256 of its host token, and
  that derivation is what makes a room resumable (`docs/adr/0008`) — do not
  change it to a fresh random value.
- **Two ports, on purpose.** `fw_room_store` (hash to process) and
  `fw_room_snapshots` (what survives a restart). Everything else the domain
  needs arrives as a value, and a behaviour with one implementation and no
  prospect of a second is ceremony.
- **The server holds no timezone.** Every instant is UTC; each browser
  canonicalises against its own locale (`docs/adr/0010`). There is no field for
  a location and there should not be one.

## Conventions

- Comments state constraints the code cannot: an invariant, an
  invariant's reason, why a slow path is acceptable. No narration, no history.
- Every module is prefixed `fw_`. A module's name says what it owns, singular:
  `fw_room`, `fw_mask`, `fw_grid`.
- Tagged tuples for message and command types, maps for aggregates and config,
  records only inside a single module.
- Ports are `-callback` behaviours; adapters are named for the technology they
  adapt. A port has one reason to exist — if a behaviour has grown past five
  callbacks, it is two ports.
- Errors are `{error, Reason}` with an atom or tagged tuple `Reason`. Strings
  are for humans at the edge, and the edge is `fw_web`.

## Writing tests

Unit-test the pure modules exhaustively — there is no excuse, they have no
setup. `rebar3 ct` covers the process and socket layers. Test names read as
sentences about behaviour. Assert exact values, not `>= 0`. See
`.claude/skills/testing-discipline/SKILL.md`.
