# 0002. Three layers, with a pure domain that cannot read a clock

- Status: Accepted
- Date: 2026-08-28

## Context

The rules worth getting right here are small and fiddly: when a room is closed
to changes, who may pick a slot, what counts as a valid mask, how availability
aggregates. They are also exactly the rules that are painful to test if they
are entangled with a `gen_server`, a socket, or the current time.

Erlang makes the entanglement easy to fall into. The process is where state
lives, so decisions drift into `handle_call/3`, and testing them then needs a
started application, a timer, and patience.

## Decision

Three OTP applications in an umbrella, with dependencies pointing one way:

- **`fw_core`** — the domain. Pure functions over values. No processes, no
  clock, no randomness, no ETS, no config, no JSON, no dependencies.
- **`fw_runtime`** — rooms as processes: supervision, the hash directory,
  identifiers, timers, the rate limiter.
- **`fw_web`** — cowboy: HTTP, the websocket, JSON, and the built client.

Time and entropy are *values* passed inward, never facilities the domain
reaches for. `fw_room:join(Id, Alias, Now, Room)` takes both the generated id
and the current instant as arguments.

The rule is enforced mechanically, not by review: `.claude/hooks/check_erl.escript`
rejects an edit that makes `fw_core` mention `gen_server`, `ets`, `json`,
`erlang:system_time`, `crypto:strong_rand_bytes` or a module from a layer above
it, and it builds its module index by globbing `apps/*/src` so moving a module
updates the rules automatically.

## Consequences

Domain tests need no setup at all. Every rule about expiry, capacity,
authority and aggregation is a one-line assertion against a pure function, and
the whole unit suite runs in about two seconds. Testing "a room expires exactly
at its deadline" is two calls with two different integers rather than a timer.

The process modules become boring, which is the point. `fw_room_server` decodes
a command, calls `fw_room`, keeps the answer, and tells its watchers; there is
no branch on domain state anywhere in it.

There is more indirection than a single-module implementation would need. For a
system this size that is a real cost, paid deliberately: the alternative is
that the rules are only testable through a socket.

Three applications also means three `.app.src` files, three test directories,
and a release manifest. That is the fixed cost of the umbrella and it does not
grow.

## Alternatives considered

**One application, modules only.** Fewer files, and the layering could still be
a convention. Rejected because a convention that is not checked is a
convention that decays, and the umbrella makes the check trivial: the
dependency graph is declared in `.app.src` and the hook reads the directory
layout.

**Domain modules that take a clock behaviour rather than a timestamp.** More
conventionally "hexagonal", and worse: it introduces a port, a mock, and a
setup step to answer a question that an integer already answers. Ports are for
collaborators with several operations, not for values.
