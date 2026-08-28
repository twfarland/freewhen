-module(fw_origin).
-moduledoc """
Origin policy for the websocket handshake.

An origin is not an identity and proves nothing about who is connecting. What
it does is stop another website opening a socket with a visitor's ambient
credentials, which for FreeWhen means stopping a page the visitor did not open
from reading a room they have a tab for.

`any` is the development default and accepts everything, including clients that
send no `Origin` at all. A configured list rejects both an unknown origin and a
missing one — a browser always sends the header, so its absence in production
means the caller is not the browser we serve.
""".

-export([is_allowed/2]).
-export_type([policy/0]).

-type policy() :: any | [binary()].

-spec is_allowed(cowboy_req:req(), policy()) -> boolean().
is_allowed(_Req, any) ->
    true;
is_allowed(Req, Allowed) when is_list(Allowed) ->
    lists:member(cowboy_req:header(<<"origin">>, Req, undefined), Allowed).
