---
name: hexagonal-layers
description: Where a new module goes, what each layer may depend on, and how ports and adapters are written in this Erlang umbrella. Load before adding a module, adding a dependency, or when unsure which app owns a piece of behaviour.
---

# Layers, ports and adapters

Three apps. Dependencies point one way, downward, and nothing points back up.

```
        fw_web        http/  ws/  json/
           |
      fw_runtime      ports/  rooms/  support/
           |
       fw_core        domain/ — pure, no processes, no I/O, no config
```

Inside an app, the directory says what a module *is*. A new module goes in the
one that describes its role, and if none of them fits, that is worth a moment's
thought before adding a directory.

The browser client is TypeScript with Lit templates, under `web/`, built into
`apps/fw_web/priv/static`. It owns everything about timezones and rendering,
because the server deals only in UTC slot indices and counts.

## Deciding where something goes

Ask what the code needs in order to be correct.

- Needs only its arguments → **`fw_core`**. Rules, arithmetic, validation,
  invariants, value objects, aggregate state transitions.
- Needs the clock, entropy, concurrency, or a lifetime → **`fw_runtime`**.
  Anything with a pid, a timer, or a table.
- Needs a socket, a header, a JSON shape, or a URL → **`fw_web`**.

The most common mistake is putting a decision in `fw_runtime` because that is
where the process is. A `gen_server` should read as: decode the request, call
`fw_core`, keep the answer, reply. When a `handle_call/3` clause branches on
domain state, that branch belongs in `fw_core`, and the process should be
calling a function that has already made the choice.

## Purity in `fw_core`

Pure means no `system_time`, no `rand`, no `self()`, no `application:get_env`,
no message send, no ETS. A domain function that needs the time takes it as an
argument, and the caller — which is allowed to know what time it is —
supplies it.

```erlang
%% fw_runtime
Now = erlang:system_time(millisecond),
{ok, Room1} = fw_room:join(Alias, Id, Now, Room0).
```

This is not ceremony. It is what makes every domain test a one-line assertion
with no setup, no mocking library and no flakiness, and it is why the domain
suite runs in milliseconds.

## Ports

A port is a `-callback` behaviour declared **by the layer that needs it**, not
by the layer that implements it: the inner layer states its requirement and the
outer layer satisfies it.

There is exactly one: `fw_room_store`, which resolves a room hash to the
process holding it. It earns its place because every change to how rooms
survive a restart goes through it, and the implementation is chosen in
`fw_settings` so a test can supply its own.

Resist adding a second. Most dependencies dissolve under rule 1 below —
`fw_core` takes `Now` as an argument rather than owning a clock port — and a
behaviour with one implementation and no prospect of another is ceremony, not
architecture.

Rules for a port:

- Five callbacks at most. Past that it is two ports sharing a name.
- Its types are the inner layer's types. A port that mentions `cowboy_req` is
  not a port.
- It carries a `Ctx` term, opaque to the caller, so the adapter can hold its
  own configuration without the inner layer knowing the shape.
- Document what each callback must guarantee, especially about ordering and
  failure. The implementer has only the behaviour to go on.

## Adapters

An adapter is named for the technology it adapts and contains no decisions:

```erlang
-module(fw_ids_crypto).
-behaviour(fw_ids).
```

If an adapter starts making choices — which slot to pick, whether a mask is
valid — that logic escaped from `fw_core`. Move it back.

## Adding a dependency

New third-party dependencies need an ADR. The list today is `cowboy` at
runtime, `gun` in the test profile, and `lit` in the browser; JSON comes from
OTP's own `json` module.
Every dependency is code that has to be audited, patched and shipped, and this
application's entire claim is that it holds nothing worth attacking — a claim
that gets harder to make with each library in the release.

`fw_core` has *no* dependencies beyond stdlib, and `lit` has none of its own.
Both are properties worth defending.
