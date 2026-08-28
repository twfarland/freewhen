-module(fw_ws_client).
-moduledoc "A websocket client for the integration suite.".

-export([connect/2, upgrade_status/2, close/1, send/2, recv/1, silent/1]).
-export([join/2, submit/3, pick/3]).

-define(TIMEOUT, 5_000).

connect(Port, Hash) ->
    {Pid, Stream} = open(Port, Hash),
    receive
        {gun_upgrade, Pid, Stream, [<<"websocket">>], _Headers} -> {Pid, Stream}
    after ?TIMEOUT -> error(websocket_upgrade_failed)
    end.

-doc "The HTTP status of a refused upgrade, for the cases where refusal is the point.".
upgrade_status(Port, Hash) ->
    {Pid, Stream} = open(Port, Hash),
    Status =
        receive
            {gun_response, Pid, Stream, _Fin, Code, _Headers} -> Code;
            {gun_upgrade, Pid, Stream, _Protocols, _Headers} -> upgraded
        after ?TIMEOUT -> error(no_response)
        end,
    gun:close(Pid),
    Status.

close({Pid, _Stream}) -> gun:close(Pid).

%%% ---- messages ----

join(Socket, Alias) ->
    send(Socket, #{<<"type">> => <<"join">>, <<"alias">> => Alias}).

submit(Socket, Id, Busy) ->
    send(Socket, #{<<"type">> => <<"submit">>, <<"attendeeId">> => Id, <<"busy">> => Busy}).

pick(Socket, Token, Slot) ->
    send(Socket, #{<<"type">> => <<"pick">>, <<"hostToken">> => Token, <<"slot">> => Slot}).

%%% ---- frames ----

send({Pid, Stream}, Message) ->
    gun:ws_send(Pid, Stream, {text, fw_json:encode(Message)}).

recv({Pid, Stream}) ->
    receive
        {gun_ws, Pid, Stream, {text, Frame}} ->
            {ok, Decoded} = fw_json:decode(Frame),
            Decoded;
        {gun_ws, Pid, Stream, {close, _Code, _Reason}} ->
            error(closed_by_host)
    after ?TIMEOUT -> error(no_frame_arrived)
    end.

-doc "Assert the host has nothing more to say, for cases where an extra frame is the bug.".
silent({Pid, Stream}) ->
    receive
        {gun_ws, Pid, Stream, Frame} -> error({unexpected_frame, Frame})
    after 300 -> ok
    end.

%%% ---- internal ----

open(Port, Hash) ->
    {ok, Pid} = gun:open("localhost", Port, #{protocols => [http]}),
    {ok, http} = gun:await_up(Pid, ?TIMEOUT),
    {Pid, gun:ws_upgrade(Pid, "/ws/rooms/" ++ binary_to_list(Hash))}.
