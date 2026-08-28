-module(fw_ws_handler).
-moduledoc """
One connection, one room.

The hash is taken from the path and resolved **before** the upgrade, so a link
to a room that has expired fails as an honest 404 rather than as a socket that
opens and then says nothing. Resolving before upgrading is also what keeps this
handler from being a way to create rooms: it only ever finds one that already
exists, and creating costs a day of memory and lives behind the rate-limited
`POST /api/rooms`.

A successful command sends no reply of its own. The change it caused arrives as
the next `state` message, which every watcher gets including the sender, so
there is exactly one way for a client to learn what happened. Only failures and
the id handed back by joining need a direct answer.

Nothing here logs a frame or a path. The hash is the capability that opens the
room, and a log file is the one place it must never appear.
""".

-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

-record(state, {room :: pid()}).

-spec init(cowboy_req:req(), map()) ->
    {cowboy_websocket, cowboy_req:req(), #state{}, cowboy_websocket:opts()}
    | {ok, cowboy_req:req(), map()}.
init(Req, Opts) ->
    case admit(Req, Opts) of
        {ok, Room} -> {cowboy_websocket, Req, #state{room = Room}, socket_opts(Opts)};
        {error, Status} -> {ok, cowboy_req:reply(Status, #{}, <<>>, Req), Opts}
    end.

%% Monitor as well as watch: the room monitors us so it can forget a dropped
%% connection, and we monitor it so an expiry reaches the client as a `closed`
%% rather than as a socket that goes quiet.
-spec websocket_init(#state{}) -> {[{text, binary()}], #state{}}.
websocket_init(#state{room = Room} = State) ->
    _Monitor = erlang:monitor(process, Room),
    {ok, Snapshot} = fw_room_server:watch(Room, self()),
    {[{text, fw_room_json:state(Snapshot)}], State}.

-spec websocket_handle(ping | pong | {text | binary | ping | pong, binary()}, #state{}) ->
    {[{text, binary()}], #state{}}.
websocket_handle({text, Frame}, #state{room = Room} = State) ->
    {handle(Frame, Room), State};
websocket_handle(_Other, State) ->
    {[], State}.

-spec websocket_info(term(), #state{}) ->
    {[{text, binary()} | close], #state{}}.
websocket_info({room_changed, Room}, State) ->
    {[{text, fw_room_json:state(Room)}], State};
websocket_info({'DOWN', _Monitor, process, _Pid, Reason}, State) ->
    {[{text, fw_room_json:closed(ended(Reason))}, close], State};
websocket_info(_Other, State) ->
    {[], State}.

%%% ---- internal ----

admit(Req, Opts) ->
    case fw_origin:is_allowed(Req, maps:get(allowed_origins, Opts, any)) of
        false -> {error, 403};
        true -> resolve(cowboy_req:binding(hash, Req))
    end.

resolve(undefined) ->
    {error, 400};
resolve(Hash) ->
    case fw_rooms:find(Hash) of
        {ok, Room} -> {ok, Room};
        error -> {error, 404}
    end.

handle(Frame, Room) ->
    case fw_room_json:command(Frame) of
        {ok, Command} -> answer(Room, Command);
        {error, Why} -> [{text, fw_room_json:error(Why)}]
    end.

%% A room can expire between any two frames, so every command is allowed to
%% find it already gone.
answer(Room, Command) ->
    try fw_room_server:command(Room, Command) of
        {ok, {joined, Id}} -> [{text, fw_room_json:joined(Id)}];
        {ok, ok} -> [];
        {error, Reason} -> [{text, fw_room_json:error(Reason)}]
    catch
        exit:_Reason -> [{text, fw_room_json:closed(expired)}, close]
    end.

%% A room that stopped normally expired or was finalised; anything else failed.
ended(normal) -> expired;
ended(_Reason) -> failed.

socket_opts(Opts) ->
    #{
        max_frame_size => maps:get(max_frame_bytes, Opts, 65_536),
        idle_timeout => maps:get(idle_timeout_ms, Opts, 60_000)
    }.
