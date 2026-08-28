---
name: erlang-style
description: House style for Erlang/OTP in this repo — module shape, typing discipline, naming, error handling, size limits, and the specific things that fail CI. Load before writing or editing any .erl file, and before deciding how to split a module that has grown too large.
---

# Erlang style

The compiler runs with `warnings_as_errors` and `warn_missing_spec`. Dialyzer
and xref must be clean. Most of this guide is therefore enforced rather than
advised; what follows is how to satisfy it without fighting it.

## Module shape

Order, top to bottom, always:

```erlang
-module(fw_thing).
-moduledoc "One sentence: what this module owns.".

-behaviour(...).          % if any

-export([...]).           % the public face, grouped by purpose
-export_type([t/0]).

-opaque t() :: #{...}.    % the type this module owns
-type reason() :: full | expired.

%%% ---- construction ----
%%% ---- queries ----
%%% ---- commands ----
%%% ---- internal ----
```

Exports are grouped and ordered by what a reader needs first: build it, ask it
things, tell it things. Internal functions come last, in call order, so the
file reads downward.

Use `-moduledoc` and `-doc` (OTP 27) rather than `@doc` comments. One sentence
on the module; a `-doc` on any export whose contract is not obvious from its
name and spec.

## Types

- Every export has a `-spec`. No exceptions; the compiler will stop you.
- The type a module owns is `-opaque`, exported via `-export_type`, and reached
  only through that module's accessors. This is the Law of Demeter with teeth:
  Dialyzer fails the build when another module pattern-matches your internals.
- Name the type `t()`. `fw_mask:t()` reads better than `fw_mask:mask()`.
- Prefer a narrow union to a wide primitive. `-type slot() :: non_neg_integer()`
  costs nothing and documents every signature it appears in.
- Never declare a type as bare `term()` because the shape is inconvenient. If
  you cannot describe the shape, you do not yet understand it.
- Return types are exact: `{ok, t()} | {error, reason()}`, never
  `{ok, t()} | term()`.

## Size

200 lines per module, 30 per function, both enforced by
`.claude/hooks/check_erl.escript`. When you hit a limit:

- A long function is usually a pipeline. Name each stage and let the top-level
  function read as its list of steps.
- A long module is usually two nouns sharing a file. Split by the thing owned,
  not by "helpers" — a `*_utils` module is a failure to find the noun.
- A long `case` is usually a dispatch table or a set of function clauses.
  Prefer clauses with guards; the compiler checks those for you.

## Error handling

- Return `{error, Reason}` for outcomes a caller can reasonably handle, where
  `Reason` is an atom or a tagged tuple. Reserve exceptions for broken
  invariants.
- Do not write catch-all clauses on data you control. An unmatched shape should
  crash so a supervisor can act; a catch-all turns a loud bug into a silent one.
- Do write an explicit clause for every case you *do* expect, including the
  boring ones. `handle_info/2` needs its unexpected-message clause because the
  VM can deliver anything; a domain function does not.
- `try ... catch` only where you cross a trust boundary — decoding a frame,
  parsing input — and only around the smallest possible expression.

## Naming

- Modules are singular nouns for what they own: `fw_room`, `fw_mask`.
- Functions are verbs for commands (`join/3`, `pick/3`) and nouns for queries
  (`heatmap/1`, `attendees/1`). A query never mutates; a command returns the
  new value.
- Predicates start with `is_`.
- Variables spell out the noun: `Attendees`, not `As`. Single letters are for
  arithmetic only.
- No invented abbreviations. `Msg`, `Ref`, `Pid`, `Opts`, `Ctx` are already the
  language's vocabulary; yours are not.

## Processes

- A `gen_server` callback module holds *no* logic. It receives a message, calls
  a pure function, stores the result, and replies. If you are tempted to write
  a branch on domain state inside `handle_call/3`, that branch belongs one
  layer down.
- State is a record or map defined in that module and never exposed.
- `handle_info/2` ends with a clause that logs at debug and ignores. That is
  the one legitimate catch-all, because the VM is not a trusted caller.
- `terminate/2` may do best-effort cleanup, but never rely on it: it does not
  run for `exit(Pid, kill)`.
- Monitor, do not link, when you want to observe a peer without dying with it.
  Always `demonitor(Ref, [flush])`.

## Dependency injection

Dependencies arrive as arguments, in this order of preference:

1. **A plain value.** Pass `Now` (a timestamp), not a clock module. Pass the
   generated id, not the generator. Most "ports" dissolve under this rule, and
   the pure function that results needs no test double at all.
2. **A behaviour module plus its context**, when the collaborator is genuinely
   an external system with several operations: `Mod:lookup(Name, Args, Ctx)`.
3. Config is read exactly once, in an application's `start/2`, and reaching for
   `application:get_env/2` anywhere else is the bug. `fw_settings` holds the
   result; every other module takes what it needs as an argument.

## Things that reliably break the build

- A missing `-spec` on a new export.
- An `-opaque` type inspected from another module (Dialyzer reports an opaque
  term violation).
- An unused local function (xref `locals_not_used`) — delete it rather than
  exporting it to quiet the check.
- `binary_to_atom/2` on network input.
- An unmatched return in statement position; bind it, or prefix with `_ =`.
