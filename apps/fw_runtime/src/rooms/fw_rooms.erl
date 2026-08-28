-module(fw_rooms).
-moduledoc """
Opening, finding and restoring rooms: the runtime's front door, and the only
way a room comes into existence.

Not reachable from the websocket. Creating costs a day of memory and must be
rate limited and capped; finding an existing room costs nothing, so the socket
handler resolves hashes and never creates.

## Coming back

Three mechanisms, in the order they apply. `restore/0` runs at boot and brings
back every room the snapshot store still holds, which covers an ordinary
release. `resume/2` reopens a room from its host token, which covers a
snapshot store that was empty or lost. `create/1` mints a new one.

`create/1` derives the hash from a fresh token; `resume/2` derives it from a
token the caller already holds. Same derivation, so the same room comes back at
the same address — see `docs/adr/0008`. Resuming a live room is a no-op that
returns the same answer, so a client can call it whenever the room seems
missing without knowing why.

The host token is returned once per call and never stored anywhere it can be
read back. Losing it loses both the right to pick a slot and the ability to
resume.
""".

-export([create/1, resume/2, find/1, count/0, restore/0]).
-export_type([created/0, params/0, error/0]).

-type params() :: #{grid := fw_grid:t(), duration_slots := pos_integer()}.
-type created() :: #{hash := fw_room_store:hash(), host_token := fw_room:token()}.
-type error() :: at_capacity | forbidden | fw_room:error().

-spec create(params()) -> {ok, created()} | {error, error()}.
create(Params) -> open(fw_ids:host_token(), Params).

-doc "Reopen a room at the address its token derives, creating it if it is gone.".
-spec resume(fw_room:token(), params()) -> {ok, created()} | {error, error()}.
resume(Token, Params) when is_binary(Token), byte_size(Token) > 0 ->
    open(Token, Params);
resume(_NotAToken, _Params) ->
    {error, forbidden}.

-spec find(fw_room_store:hash()) -> {ok, pid()} | error.
find(Hash) ->
    Store = store(),
    Store:find(Hash).

-spec count() -> non_neg_integer().
count() ->
    Store = store(),
    Store:count().

-doc """
Bring back every room the snapshot store still holds. Returns how many.

Rooms whose deadline passed while the node was down are dropped rather than
revived: expiry is a promise about wall-clock time, not about uptime.
""".
-spec restore() -> non_neg_integer().
restore() ->
    Settings = fw_settings:get(),
    Snapshots = maps:get(snapshots, Settings),
    Now = fw_clock:now_ms(),
    length([ok || {Hash, Room} <- Snapshots:all(), revived(Hash, Room, Now, Settings)]).

%%% ---- internal ----

revived(Hash, Room, Now, Settings) ->
    Snapshots = maps:get(snapshots, Settings),
    case fw_room:is_expired(Now, Room) of
        true ->
            ok = Snapshots:forget(Hash),
            false;
        false ->
            {ok, _Pid} = start(Hash, Room, Settings),
            true
    end.

open(Token, Params) ->
    Hash = fw_ids:hash_of(Token),
    case find(Hash) of
        {ok, _Live} -> {ok, #{hash => Hash, host_token => Token}};
        error -> admit(Hash, Token, Params, fw_settings:get())
    end.

admit(Hash, Token, Params, Settings) ->
    case count() >= maps:get(max_rooms, Settings) of
        true -> {error, at_capacity};
        false -> build(Hash, Token, Params, Settings)
    end.

build(Hash, Token, #{grid := Grid, duration_slots := Duration}, Settings) ->
    Params = #{
        grid => Grid,
        duration_slots => Duration,
        host_token => Token,
        capacity => maps:get(max_attendees_per_room, Settings),
        ttl_ms => maps:get(room_ttl_ms, Settings)
    },
    case fw_room:new(Params, fw_clock:now_ms()) of
        {ok, Room} -> opened(Hash, Token, Room, Settings);
        {error, Reason} -> {error, Reason}
    end.

opened(Hash, Token, Room, Settings) ->
    {ok, _Pid} = start(Hash, Room, Settings),
    {ok, #{hash => Hash, host_token => Token}}.

%% Two callers resuming the same token at once is the realistic race. The loser
%% discards its process and reports the winner's room rather than replacing it.
start(Hash, Room, Settings) ->
    Args = #{
        hash => Hash,
        room => Room,
        grace_ms => maps:get(finalize_grace_ms, Settings),
        snapshots => maps:get(snapshots, Settings)
    },
    {ok, Pid} = fw_room_sup:start_room(Args),
    Store = store(),
    case Store:insert(Hash, Pid) of
        ok -> {ok, Pid};
        {error, collision} -> discard(Hash, Pid)
    end.

discard(Hash, Pid) ->
    ok = supervisor:terminate_child(fw_room_sup, Pid),
    find(Hash).

store() -> maps:get(room_store, fw_settings:get()).
