-module(fw_clock).
-moduledoc """
Where "now" enters the system.

A one-line module earns its place by being the only line: `fw_core` takes the
time as an argument precisely so that no domain rule can read a clock, and this
is the boundary that makes that true rather than aspirational.
""".

-export([now_ms/0]).

-spec now_ms() -> fw_grid:millisecond().
now_ms() -> erlang:system_time(millisecond).
