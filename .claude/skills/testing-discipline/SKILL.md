---
name: testing-discipline
description: How this repo tests — what belongs in eunit vs common_test, naming, and the rules against mocking and sleeping. Load before writing a test, before adding a test dependency, or when a test is flaky.
---

# Testing

Two suites, split by what they need in order to run.

| tool | covers | may use |
|---|---|---|
| `rebar3 eunit` | `fw_core`, `fw_bucket` | nothing but the module under test |
| `rebar3 ct` | `fw_runtime`, `fw_web` | processes, sockets, the real release |

If a unit test needs a process, it is testing the wrong layer. If an
integration test asserts an arithmetic result, that assertion belongs in a unit
test where it will run a thousand times faster.

## Unit tests

Live in `apps/<app>/test/<module>_tests.erl`. The domain is pure, so the shape
is always the same and there is never any setup:

```erlang
intersecting_a_busy_slot_removes_it_from_the_heatmap_test() ->
    Grid = fw_grid:new(0, 15, 4),
    Free = fw_mask:free(Grid),
    Busy = fw_mask:from_slots([1], Grid),
    ?assertEqual([2, 1, 2, 2], fw_heatmap:counts([Free, Busy, Free], Grid)).
```

- One behaviour per test. A test that needs "and also" in its name is two
  tests.
- Test names are sentences: what is true, under what condition. They are read
  far more often in failure output than in the file.
- Assert exact values. `?assertEqual([2,1,2,2], ...)`, never
  `?assert(length(X) > 0)`. A test that cannot fail on a wrong answer is not a
  test.
- Cover the boundaries deliberately: empty, one, full, one past full,
  out of order, duplicate. Those are where the bugs are.
- Group related cases with `_test_()` generators returning a list, so one
  failure does not hide the next.

## No mocks

There is no mocking library in this repo and there should not be one. The
domain is pure and takes its dependencies as values, so there is nothing to
mock. When a test needs a collaborator, write a real one in the test
directory — a twenty-line module implementing the behaviour, with state in an
ETS table owned by the test process.

A hand-written double is deterministic, readable in the failure, and forces the
port to stay small. If writing the double is painful, the port is too big.

## Integration tests

Live in `apps/<app>/test/<name>_SUITE.erl`. They boot the real application and
speak to it over a real socket.

- `init_per_suite` starts the application and returns the port in `Config`.
  Bind port `0` and read back the assigned one; a hard-coded port makes the
  suite fail on a busy machine and unrunnable in parallel.
- Never `timer:sleep/1` to wait for something. Poll for the condition with a
  deadline, or make the code under test send a message you can receive. A
  sleep is either flaky or slow, and usually both.
- Assert on observable behaviour through the public interface. A test that
  reaches into a `gen_server`'s state with `sys:get_state/1` will break on
  every refactor and protects nothing.
- Clean up in `end_per_suite`. Rooms are ephemeral by design, but a leaked
  listener will fail the next suite.

## Coverage

`rebar3 cover` after `eunit` and `ct`. The target is not a number: `fw_core`
should be near total, because it is pure and there is no excuse. Adapters are
covered by the integration suites, and a line in a cowboy handler that only
runs on a malformed request still needs a test that sends a malformed request.

## When a test is flaky

Fix it or delete it the same day. A test that fails one run in twenty trains
everyone to ignore red, which costs more than the test was ever worth. The
usual causes here, in order: a sleep standing in for synchronisation, a
hard-coded port, and a test asserting on map iteration order.
