-module(fw_schedule).
-moduledoc """
What a room looks like to the people in it: how many are free in each slot, the
windows worth meeting in, and the settled meeting once there is one.

Split from `fw_room` because the aggregate owns the *rules* and this owns the
*view*. Everything here is derived and nothing is stored — it reads a room
through the same public accessors any caller has — so changing what is
published cannot reach a rule by accident.
""".

-export([heatmap/1, proposals/1, chosen/1]).

%% More than a handful of suggestions is a list nobody reads, and the ones
%% below the fifth are always worse than the ones above it.
-define(MAX_PROPOSALS, 5).

-spec heatmap(fw_room:t()) -> fw_heatmap:counts().
heatmap(Room) ->
    Answers = [fw_attendee:availability(A) || A <- answered_by(Room)],
    fw_heatmap:counts(Answers, fw_room:grid(Room)).

-spec proposals(fw_room:t()) -> [fw_proposal:t()].
proposals(Room) ->
    Grid = fw_room:grid(Room),
    Duration = fw_room:duration_slots(Room),
    Windows = fw_heatmap:windows(heatmap(Room), Duration, Grid),
    [proposal(W, Room) || W <- fw_heatmap:best(Windows, ?MAX_PROPOSALS)].

-doc "The settled meeting, or `undefined` while the room is still open.".
-spec chosen(fw_room:t()) -> fw_proposal:t() | undefined.
chosen(Room) -> settled(fw_room:picked(Room), Room).

%%% ---- internal ----

settled(undefined, _Room) -> undefined;
settled(Slot, Room) -> proposal(#{start => Slot, free => answered(Room)}, Room).

proposal(Window, Room) ->
    fw_proposal:of_window(Window, fw_room:duration_slots(Room), fw_room:grid(Room)).

%% An attendee who has said nothing must not be counted as free, or one silent
%% invitee would make every slot look possible.
answered_by(Room) ->
    [A || A <- fw_room:attendees(Room), fw_attendee:has_availability(A)].

answered(Room) -> length(answered_by(Room)).
