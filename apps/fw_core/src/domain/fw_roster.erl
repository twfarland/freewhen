-module(fw_roster).
-moduledoc """
Who is in a meeting, and what each of them said.

Split from `fw_room` because the aggregate owns the *rules* and this owns the
*bookkeeping* — admitting somebody, recording an answer, and the one question
the rules ask of it: whether everybody here has answered yet, which is the gate
on choosing a time.

Order is held apart from the members so the list a client renders does not
reshuffle itself every time somebody answers.
""".

-export([empty/0, add/4, answer/3, list/1, everyone_answered/1, without_silent/1]).
-export_type([t/0, error/0]).

-type error() :: full | duplicate | unknown_attendee | fw_attendee:error().

-opaque t() :: #{
    members := #{fw_attendee:id() => fw_attendee:t()},
    order := [fw_attendee:id()]
}.

-spec empty() -> t().
empty() -> #{members => #{}, order => []}.

-doc "Admit somebody, up to `Capacity`.".
-spec add(fw_attendee:id(), fw_attendee:alias(), pos_integer(), t()) ->
    {ok, t()} | {error, error()}.
add(Id, Alias, Capacity, #{members := Members} = Roster) ->
    case {maps:is_key(Id, Members), maps:size(Members) >= Capacity} of
        {true, _AtCapacity} -> {error, duplicate};
        {false, true} -> {error, full};
        {false, false} -> attach(fw_attendee:new(Id, Alias), Id, Roster)
    end.

-doc "Record when somebody can meet. Answering again replaces the last answer.".
-spec answer(fw_attendee:id(), fw_availability:t(), t()) -> {ok, t()} | {error, error()}.
answer(Id, Availability, #{members := Members} = Roster) ->
    case maps:find(Id, Members) of
        {ok, Attendee} ->
            Answered = fw_attendee:with_availability(Availability, Attendee),
            {ok, Roster#{members := Members#{Id => Answered}}};
        error ->
            {error, unknown_attendee}
    end.

-doc "In the order they joined, so the list does not reshuffle itself.".
-spec list(t()) -> [fw_attendee:t()].
list(#{members := Members, order := Order}) -> [maps:get(Id, Members) || Id <- Order].

-doc """
Whether everybody here has said when they are free.

False for an empty roster: a time cannot be chosen for nobody, and this is the
gate deciding whether one may be chosen at all.
""".
-spec everyone_answered(t()) -> boolean().
everyone_answered(#{order := []}) -> false;
everyone_answered(Roster) -> lists:all(fun fw_attendee:has_availability/1, list(Roster)).

-doc """
Forget everybody who never answered.

The way out of the only deadlock the gate can produce: somebody opens the link,
goes away, and their silence would otherwise stop the meeting being arranged at
all. It names nobody — the host says "without whoever is missing" and the room
works out who that is — so no attendee id has to be published for it.
""".
-spec without_silent(t()) -> t().
without_silent(#{members := Members, order := Order}) ->
    Kept = maps:filter(fun(_Id, A) -> fw_attendee:has_availability(A) end, Members),
    #{members => Kept, order => [Id || Id <- Order, maps:is_key(Id, Kept)]}.

%%% ---- internal ----

attach({ok, Attendee}, Id, #{members := Members, order := Order} = Roster) ->
    {ok, Roster#{members := Members#{Id => Attendee}, order := Order ++ [Id]}};
attach({error, Reason}, _Id, _Roster) ->
    {error, Reason}.
