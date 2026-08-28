-module(fw_health_handler).
-moduledoc """
`GET /healthz` — liveness, and the only numbers this system will ever report.

A room count and an uptime. There is nothing else to expose: per-room metrics
would be a directory of which rooms exist and how busy they are, which is
exactly the information the design promises not to keep.
""".

-export([init/2]).

-spec init(cowboy_req:req(), map()) -> {ok, cowboy_req:req(), map()}.
init(Req, State) ->
    Body = #{
        <<"status">> => <<"ok">>,
        <<"rooms">> => fw_rooms:count(),
        <<"uptimeSeconds">> => uptime_seconds()
    },
    Headers = #{
        <<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"cache-control">> => <<"no-store">>
    },
    {ok, cowboy_req:reply(200, Headers, fw_json:encode(Body), Req), State}.

%%% ---- internal ----

uptime_seconds() ->
    {Milliseconds, _Since} = erlang:statistics(wall_clock),
    Milliseconds div 1000.
