-module(fw_proposal).
-moduledoc """
A meeting time the room can offer: when it is, and how many people can be there.

Carries the UTC instants rather than only the slot index, because the browser
should never have to work out what a slot number means. It formats these two
numbers in the viewer's own locale and does no arithmetic of its own.
""".

-export([of_window/3, slot/1, free/1, starts_at/1, ends_at/1]).
-export_type([t/0]).

-opaque t() :: #{
    slot := fw_grid:slot(),
    free := non_neg_integer(),
    starts_at := fw_grid:millisecond(),
    ends_at := fw_grid:millisecond()
}.

-spec of_window(fw_heatmap:window(), pos_integer(), fw_grid:t()) -> t().
of_window(#{start := Slot, free := Free}, Length, Grid) ->
    {StartsAt, EndsAt} = fw_grid:window(Slot, Length, Grid),
    #{slot => Slot, free => Free, starts_at => StartsAt, ends_at => EndsAt}.

-spec slot(t()) -> fw_grid:slot().
slot(#{slot := Slot}) -> Slot.

-doc "How many attendees are free for the whole window.".
-spec free(t()) -> non_neg_integer().
free(#{free := Free}) -> Free.

-spec starts_at(t()) -> fw_grid:millisecond().
starts_at(#{starts_at := StartsAt}) -> StartsAt.

-spec ends_at(t()) -> fw_grid:millisecond().
ends_at(#{ends_at := EndsAt}) -> EndsAt.
