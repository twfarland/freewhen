-module(fw_json).
-moduledoc """
JSON, which is a concern of the edge and of nowhere else.

OTP's `json` module is the codec; this exists to name the value type and to
turn a decode failure into a return value rather than an exception, because
every byte it is handed came from an untrusted client.
""".

-export([decode/1, encode/1]).
-export_type([t/0, object/0]).

-type t() :: null | boolean() | number() | binary() | [t()] | object().
-type object() :: #{binary() => t()}.

-spec decode(binary()) -> {ok, t()} | {error, invalid_json}.
decode(Bin) ->
    try json:decode(Bin) of
        Value -> {ok, Value}
    catch
        error:_ -> {error, invalid_json}
    end.

-spec encode(t()) -> binary().
encode(Value) -> iolist_to_binary(json:encode(Value)).
