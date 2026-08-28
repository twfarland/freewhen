-module(fw_peer).
-moduledoc """
Who to charge a rate limit to.

Behind Fly's proxy every connection arrives from the same address, so the peer
socket is useless as a key and `fly-client-ip` is the real one. That header is
trustworthy only because the proxy sets it and clients cannot reach the node
directly; anywhere that is not true, the socket address is the honest answer.

The result is a rate-limiting key and nothing else. It is never stored, never
logged, and never attached to a room.
""".

-export([key/1]).

-spec key(cowboy_req:req()) -> binary().
key(Req) ->
    case cowboy_req:header(<<"fly-client-ip">>, Req, undefined) of
        undefined -> socket_address(Req);
        Address -> Address
    end.

%%% ---- internal ----

socket_address(Req) ->
    {Address, _Port} = cowboy_req:peer(Req),
    list_to_binary(inet:ntoa(Address)).
