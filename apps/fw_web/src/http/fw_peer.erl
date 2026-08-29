-module(fw_peer).
-moduledoc """
Who to charge a rate limit to.

The node binds to loopback and the reverse proxy on the same host is the only
thing that can reach it, so every connection arrives from 127.0.0.1 and the
socket address is useless as a key. `x-forwarded-for` carries the real one.

Caddy *appends* the address it saw to whatever the client sent, so the honest
entry is the last and never the first: a client that forges the header only
prepends a lie. Without a proxy in front the header is absent and the socket
address is the honest answer — which is also why the node must not be
reachable directly, or the header would be worth nothing.

The result is a rate-limiting key and nothing else. It is never stored, never
logged, and never attached to a room.
""".

-export([key/1]).

-spec key(cowboy_req:req()) -> binary().
key(Req) ->
    case cowboy_req:header(<<"x-forwarded-for">>, Req, undefined) of
        undefined -> socket_address(Req);
        Forwarded -> nearest(Forwarded, Req)
    end.

%%% ---- internal ----

nearest(Forwarded, Req) ->
    [Nearest | _Claimed] = lists:reverse(binary:split(Forwarded, <<",">>, [global])),
    case trimmed(Nearest) of
        <<>> -> socket_address(Req);
        Address -> Address
    end.

%% Leading space only: cowboy has already stripped trailing whitespace from the
%% header value, and the separator in `a, b` puts the space at the front.
trimmed(<<$\s, Rest/binary>>) -> trimmed(Rest);
trimmed(<<$	, Rest/binary>>) -> trimmed(Rest);
trimmed(Address) -> Address.

socket_address(Req) ->
    {Address, _Port} = cowboy_req:peer(Req),
    list_to_binary(inet:ntoa(Address)).
