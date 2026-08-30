-module(fw_schedule).
-moduledoc """
What a room looks like to the people in it: how far the meeting has got, how
many are free in each slot, the windows worth meeting in, and the chosen time.

Split from `fw_room` because the aggregate owns the *rules* and this owns the
*view*. Everything here is derived and nothing is stored — it reads a room
through the same public accessors any caller has — so changing what is
published cannot reach a rule by accident.
""".

-export([phase/1, heatmap/1, proposals/1, chosen/1]).
-export_type([phase/0]).

-type phase() :: collecting | ready | confirmed | provisional.

%% More than a handful of suggestions is a list nobody reads, and the ones
%% below the fifth are always worse than the ones above it.
-define(MAX_PROPOSALS, 5).

%% How far apart two suggestions have to be to count as different offers. Four
%% hours is another part of the day or another day; anything closer is the same
%% answer shifted by a slot. Never so far that the grid cannot hold a full
%% list — on a short grid the separation gives way to the list.
-define(APART_MINUTES, 240).

-doc """
Where the meeting has got to.

`collecting` — somebody here has not said when they are free, so no time may be
chosen yet. `ready` — everybody has, and the host may choose. `confirmed` — a
time is chosen that every single person here is free for. `provisional` — a
time is chosen that somebody cannot make: either the host chose it knowing
that, or somebody's plans changed afterwards.

Derived from availability and nothing else, so a room can never claim to be
confirmed while an attendee's own answer says otherwise. There is deliberately
no separate acceptance to keep in step with it — and none is needed, because
the invitation exported from a confirmed meeting is where people actually RSVP.
""".
-spec phase(fw_room:t()) -> phase().
phase(Room) -> phase(fw_room:picked(Room), Room).

-spec heatmap(fw_room:t()) -> fw_heatmap:counts().
heatmap(Room) ->
    Answers = [fw_attendee:availability(A) || A <- answered_by(Room)],
    fw_heatmap:counts(Answers, fw_room:grid(Room)).

-spec proposals(fw_room:t()) -> [fw_proposal:t()].
proposals(Room) ->
    Grid = fw_room:grid(Room),
    Duration = fw_room:duration_slots(Room),
    Windows = fw_heatmap:windows(heatmap(Room), Duration, Grid),
    [proposal(W, Room) || W <- fw_heatmap:best(Windows, apart(Duration, Grid), ?MAX_PROPOSALS)].

-doc "The chosen meeting, carrying how many can actually make it.".
-spec chosen(fw_room:t()) -> fw_proposal:t() | undefined.
chosen(Room) -> settled(fw_room:picked(Room), Room).

%%% ---- internal ----

phase(undefined, Room) ->
    case fw_room:everyone_answered(Room) of
        true -> ready;
        false -> collecting
    end;
phase(Slot, Room) ->
    case free_across(Slot, Room) =:= length(fw_room:attendees(Room)) of
        true -> confirmed;
        false -> provisional
    end.

settled(undefined, _Room) ->
    undefined;
settled(Slot, Room) ->
    proposal(#{start => Slot, free => free_across(Slot, Room)}, Room).

free_across(Slot, Room) ->
    fw_heatmap:free_across(heatmap(Room), Slot, fw_room:duration_slots(Room)).

apart(Duration, Grid) ->
    Wanted = ceil(?APART_MINUTES / fw_grid:slot_minutes(Grid)),
    max(Duration, min(Wanted, fw_grid:slots(Grid) div ?MAX_PROPOSALS)).

proposal(Window, Room) ->
    fw_proposal:of_window(Window, fw_room:duration_slots(Room), fw_room:grid(Room)).

%% An attendee who has said nothing must not be counted as free, or one silent
%% invitee would make every slot look possible.
answered_by(Room) ->
    [A || A <- fw_room:attendees(Room), fw_attendee:has_availability(A)].
