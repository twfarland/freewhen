-module(fw_runtime_app).
-moduledoc "Starts the room runtime, and is the one place configuration is read.".

-behaviour(application).

-include_lib("kernel/include/logger.hrl").

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> supervisor:startlink_ret().
start(_Type, _Args) ->
    Settings = fw_settings:load(),
    case fw_runtime_sup:start_link(Settings) of
        {ok, Pid} -> started(Pid);
        Other -> Other
    end.

%% Rooms come back before the first request can arrive, because the web layer
%% starts after this application has finished starting.
started(Pid) ->
    Restored = fw_rooms:restore(),
    ?LOG_INFO("freewhen restored ~b rooms", [Restored]),
    {ok, Pid}.

-spec stop(term()) -> ok.
stop(_State) -> ok.
