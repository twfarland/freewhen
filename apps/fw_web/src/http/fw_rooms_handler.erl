-module(fw_rooms_handler).
-moduledoc """
`POST /api/rooms` — the only endpoint that makes the server hold something.

Creating a room reserves memory for up to a day on nothing but an anonymous
request, so this is the one place a rate limit is load-bearing rather than
tidy. Everything else either reads existing state or is bounded by a room that
already exists.

A body carrying `resume` reopens the room that token derives, rather than
minting a new one — the mechanism by which rooms come back after a release.
It is rate limited identically, because it allocates identically.

The response carries the host token, once. Nothing will ever return it again.
""".

-export([init/2]).

-define(MAX_BODY, 1_024).

-spec init(cowboy_req:req(), map()) -> {ok, cowboy_req:req(), map()}.
init(Req, State) ->
    {Status, Body, Next} = route(cowboy_req:method(Req), Req),
    {ok, reply(Status, Body, Next), State}.

%%% ---- internal ----

route(<<"POST">>, Req) ->
    case fw_limiter:allow(fw_peer:key(Req)) of
        allowed -> read(Req);
        denied -> {429, error_body(<<"rate_limited">>), Req}
    end;
route(_Method, Req) ->
    {405, error_body(<<"method_not_allowed">>), Req}.

read(Req) ->
    case cowboy_req:read_body(Req, #{length => ?MAX_BODY}) of
        {ok, Body, Next} ->
            {Status, Answer} = requested(Body),
            {Status, Answer, Next};
        {more, _Partial, Next} ->
            {413, error_body(<<"body_too_large">>), Next}
    end.

requested(Body) ->
    case fw_json:decode(Body) of
        {ok, Request} -> validated(Request);
        {error, invalid_json} -> {400, error_body(<<"bad_request">>)}
    end.

validated(
    #{
        <<"startsAt">> := StartsAt,
        <<"slotMinutes">> := SlotMinutes,
        <<"slots">> := Slots,
        <<"durationSlots">> := Duration
    } = Request
) when is_integer(Duration), Duration > 0 ->
    Resume = maps:get(<<"resume">>, Request, undefined),
    open(fw_grid:new(StartsAt, SlotMinutes, Slots), Duration, Resume);
validated(_Unrecognised) ->
    {400, error_body(<<"bad_request">>)}.

open({error, Reason}, _Duration, _Resume) ->
    {400, error_body(atom_to_binary(Reason))};
open({ok, Grid}, Duration, undefined) ->
    opened(fw_rooms:create(#{grid => Grid, duration_slots => Duration}));
open({ok, Grid}, Duration, Token) when is_binary(Token) ->
    opened(fw_rooms:resume(Token, #{grid => Grid, duration_slots => Duration}));
open({ok, _Grid}, _Duration, _BadResume) ->
    {400, error_body(<<"bad_request">>)}.

opened({ok, #{hash := Hash, host_token := Token}}) ->
    {201, #{<<"hash">> => Hash, <<"hostToken">> => Token}};
opened({error, at_capacity}) ->
    {503, error_body(<<"at_capacity">>)};
opened({error, Reason}) ->
    {400, error_body(atom_to_binary(Reason))}.

error_body(Reason) -> #{<<"error">> => Reason}.

reply(Status, Body, Req) ->
    Headers = #{
        <<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"cache-control">> => <<"no-store">>
    },
    cowboy_req:reply(Status, Headers, fw_json:encode(Body), Req).
