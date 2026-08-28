-module(fw_web_app).
-moduledoc "Starts the listener. Configuration is read here and nowhere below.".

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> supervisor:startlink_ret().
start(_Type, _Args) ->
    fw_web_sup:start_link(settings()).

-spec stop(term()) -> ok.
stop(_State) ->
    ok = cowboy:stop_listener(fw_web_listener).

%%% ---- internal ----

%% Two values differ between a laptop and a deployment, and both arrive from
%% the environment so that one image runs everywhere. A malformed PORT crashes
%% the boot, which is the correct response to a misconfigured deployment.
settings() ->
    #{
        port => port(os:getenv("PORT")),
        max_frame_bytes => env(max_frame_bytes, 65_536),
        idle_timeout_ms => env(idle_timeout_ms, 60_000),
        allowed_origins => origins(os:getenv("FW_ALLOWED_ORIGINS"))
    }.

port(false) -> env(port, 8080);
port(Value) -> list_to_integer(Value).

origins(false) -> env(allowed_origins, any);
origins("") -> env(allowed_origins, any);
origins(Value) -> [list_to_binary(Origin) || Origin <- string:lexemes(Value, ",")].

env(Key, Default) -> application:get_env(fw_web, Key, Default).
