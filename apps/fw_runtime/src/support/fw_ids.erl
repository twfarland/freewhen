-module(fw_ids).
-moduledoc """
Unguessable identifiers, and the one relationship between two of them.

Attendee ids are 128 bits of CSPRNG output. Host tokens are 256 bits. Both are
base64url so they survive a URL without escaping, and neither has a sequence, a
timestamp or any structure to enumerate.

**A room's hash is the SHA-256 of its host token, truncated to 128 bits.** That
is what makes a room resumable after the server restarts: presenting the token
proves the right to that hash, because nobody else can produce a token that
hashes to it. The server can therefore recreate a room it has completely
forgotten, at its original address, without having stored anything at all.

The derivation runs one way. A hash reveals nothing about the token it came
from, so sharing a room link still shares no authority.
""".

-export([attendee_id/0, host_token/0, hash_of/1]).

-define(ID_BYTES, 16).
-define(TOKEN_BYTES, 32).
-define(HASH_BYTES, 16).

-spec attendee_id() -> binary().
attendee_id() -> encode(crypto:strong_rand_bytes(?ID_BYTES)).

-spec host_token() -> fw_room:token().
host_token() -> encode(crypto:strong_rand_bytes(?TOKEN_BYTES)).

-spec hash_of(fw_room:token()) -> fw_room_store:hash().
hash_of(Token) ->
    <<Hash:?HASH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, Token),
    encode(Hash).

%%% ---- internal ----

encode(Bytes) -> base64:encode(Bytes, #{mode => urlsafe, padding => false}).
