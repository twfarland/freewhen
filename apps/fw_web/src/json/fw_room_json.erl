-module(fw_room_json).
-moduledoc """
The translation between a room and what goes over the socket.

The whole of FreeWhen's JSON knowledge, in one module: the domain has no idea
it is being published and the transport has no idea what it is publishing.

    client -> server                        server -> client
    {type: join,   alias}                   {type: state,  room}
    {type: submit, attendeeId, free}        {type: joined, attendeeId}
    {type: pick,   hostToken, slot}         {type: error,  reason}
                                            {type: closed, reason}

No correlation ids: a connection watches one room, and the only reply anyone
waits for is the id they get back from joining. Every change sends the whole
room already computed — a snapshot is about a kilobyte, so what a diff would
save is not worth the machinery on both sides. Proposals carry UTC instants
rather than slot numbers, leaving the browser nothing to do but format.

**Attendee ids are never published.** An id is a capability, so putting the
list in a snapshot would let any participant impersonate any other. A client
learns its own once, as the reply to its own join.
""".

-export([state/1, joined/1, error/1, closed/1, command/1]).

%%% ---- server to client ----

-spec state(fw_room:t()) -> binary().
state(Room) -> fw_json:encode(#{<<"type">> => <<"state">>, <<"room">> => room(Room)}).

-spec joined(fw_attendee:id()) -> binary().
joined(Id) -> fw_json:encode(#{<<"type">> => <<"joined">>, <<"attendeeId">> => Id}).

-spec error(atom() | binary()) -> binary().
error(Reason) -> fw_json:encode(#{<<"type">> => <<"error">>, <<"reason">> => text(Reason)}).

-spec closed(atom() | binary()) -> binary().
closed(Reason) -> fw_json:encode(#{<<"type">> => <<"closed">>, <<"reason">> => text(Reason)}).

%%% ---- client to server ----

-spec command(binary()) -> {ok, fw_room_server:command()} | {error, binary()}.
command(Frame) ->
    case fw_json:decode(Frame) of
        {ok, Message} -> decode(Message);
        {error, invalid_json} -> {error, <<"not json">>}
    end.

%%% ---- decoding ----

decode(#{<<"type">> := <<"join">>, <<"alias">> := Alias}) when is_binary(Alias) ->
    {ok, {join, Alias}};
decode(#{<<"type">> := <<"submit">>, <<"attendeeId">> := Id, <<"free">> := Free}) when
    is_binary(Id), is_binary(Free)
->
    submitted(Id, Free);
decode(#{<<"type">> := <<"pick">>, <<"hostToken">> := Token, <<"slot">> := Slot}) when
    is_binary(Token), is_integer(Slot)
->
    {ok, {pick, Slot, Token}};
decode(_Unrecognised) ->
    {error, <<"unrecognised message">>}.

submitted(Id, Free) ->
    case fw_slot_bits:decode(Free) of
        {ok, FreeSlots} -> {ok, {submit, Id, FreeSlots}};
        {error, Why} -> {error, Why}
    end.

%%% ---- projection ----

room(Room) ->
    #{
        <<"grid">> => grid(fw_room:grid(Room)),
        <<"durationSlots">> => fw_room:duration_slots(Room),
        <<"attendees">> => [attendee(A) || A <- fw_room:attendees(Room)],
        <<"heatmap">> => fw_schedule:heatmap(Room),
        <<"proposals">> => [proposal(P) || P <- fw_schedule:proposals(Room)],
        <<"chosen">> => chosen(fw_schedule:chosen(Room)),
        <<"expiresAt">> => fw_room:expires_at(Room)
    }.

grid(Grid) ->
    #{
        <<"startsAt">> => fw_grid:starts_at(Grid),
        <<"slotMinutes">> => fw_grid:slot_minutes(Grid),
        <<"slots">> => fw_grid:slots(Grid)
    }.

attendee(Attendee) ->
    #{
        <<"alias">> => fw_attendee:alias(Attendee),
        <<"ready">> => fw_attendee:has_availability(Attendee)
    }.

proposal(Proposal) ->
    #{
        <<"slot">> => fw_proposal:slot(Proposal),
        <<"free">> => fw_proposal:free(Proposal),
        <<"startsAt">> => fw_proposal:starts_at(Proposal),
        <<"endsAt">> => fw_proposal:ends_at(Proposal)
    }.

chosen(undefined) -> null;
chosen(Proposal) -> proposal(Proposal).

text(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
text(Reason) when is_binary(Reason) -> Reason.
