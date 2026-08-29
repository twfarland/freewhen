-module(fw_web_sup).
-moduledoc """
Owns the HTTP listener.

The listener is started here rather than in `start/2` so that a supervisor is
responsible for it, and `port/0` reads back the address actually bound — which
is what makes it possible for a test to bind port 0 and still find the server.
""".

-behaviour(supervisor).

-export([start_link/1, port/0, init/1]).

-define(LISTENER, fw_web_listener).

-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Settings) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Settings).

-doc "The port the listener actually bound, which is not the configured one when that was 0.".
-spec port() -> inet:port_number().
port() ->
    Port = ranch:get_port(?LISTENER),
    true = is_integer(Port),
    Port.

-spec init(map()) -> {ok, {supervisor:sup_flags(), []}}.
init(Settings) ->
    {ok, _Listener} = cowboy:start_clear(
        ?LISTENER,
        transport(Settings),
        #{
            env => #{dispatch => fw_web_router:dispatch(Settings)},
            middlewares => [cowboy_router, cowboy_handler]
        }
    ),
    {ok, {#{strategy => one_for_one, intensity => 1, period => 5}, []}}.

%%% ---- internal ----

%% `any` is every interface, which is right on a laptop and wrong behind a
%% proxy on the same host. See fw_peer.
transport(#{port := Port, bind := any}) -> [{port, Port}];
transport(#{port := Port, bind := Address}) -> [{port, Port}, {ip, Address}].
