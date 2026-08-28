-module(fw_web_router).
-moduledoc """
The routing table, which is the whole of this system's HTTP surface.

Two endpoints, one socket, and static files.

The room hash appears in exactly one path, the websocket upgrade, and nothing
in this application logs it. `/m/...` is served by the client, which keeps the
hash in the URL fragment so that it is never sent to the server at all when
loading the page.
""".

-export([dispatch/1]).

-spec dispatch(map()) -> cowboy_router:dispatch_rules().
dispatch(Settings) ->
    cowboy_router:compile([{'_', routes(Settings)}]).

%%% ---- internal ----

routes(Settings) ->
    [
        {"/api/rooms", fw_rooms_handler, #{}},
        {"/healthz", fw_health_handler, #{}},
        {"/ws/rooms/:hash", fw_ws_handler, Settings},
        {"/static/[...]", cowboy_static, {priv_dir, fw_web, "static"}},
        {"/m/[...]", cowboy_static, {priv_file, fw_web, "static/index.html"}},
        {"/", cowboy_static, {priv_file, fw_web, "static/index.html"}}
    ].
