-module(fw_snapshots_dets).
-moduledoc """
Rooms written down, in one stdlib DETS file.

DETS rather than a database because there is nothing here a database would do
for us: one key, one value, no queries, no joins, no schema, no server to run
and nothing to operate. It is part of OTP, so the release gains no dependency
and the deployment gains no component.

This process owns the file. Reads and writes go straight to DETS from whichever
process is asking; the server exists to hold the table open and to flush it
periodically, because DETS buffers and a hard kill would otherwise lose more
than the last few seconds.
""".

-behaviour(gen_server).
-behaviour(fw_room_snapshots).

-export([start_link/1, save/2, forget/1, all/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-define(TABLE, ?MODULE).
-define(SYNC_MS, 30_000).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Settings) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Settings, []).

-spec save(fw_room_store:hash(), fw_room:t()) -> ok.
save(Hash, Room) -> survivable(dets:insert(?TABLE, {Hash, fw_room:to_binary(Room)}), save).

-spec forget(fw_room_store:hash()) -> ok.
forget(Hash) -> survivable(dets:delete(?TABLE, Hash), forget).

-doc "Unreadable entries are dropped as they are found, not left to fail again next boot.".
-spec all() -> [{fw_room_store:hash(), fw_room:t()}].
all() -> dets:foldl(fun readable/2, [], ?TABLE).

%%% ---- gen_server ----

-spec init(map()) -> {ok, []}.
init(#{snapshot_file := Path}) ->
    ok = filelib:ensure_dir(Path),
    {ok, ?TABLE} = dets:open_file(?TABLE, [{file, Path}, {type, set}, {auto_save, ?SYNC_MS}]),
    _Timer = erlang:send_after(?SYNC_MS, self(), sync),
    {ok, []}.

-spec handle_call(term(), gen_server:from(), []) -> {reply, ok, []}.
handle_call(_Unexpected, _From, State) -> {reply, ok, State}.

-spec handle_cast(term(), []) -> {noreply, []}.
handle_cast(_Unexpected, State) -> {noreply, State}.

-spec handle_info(term(), []) -> {noreply, []}.
handle_info(sync, State) ->
    ok = dets:sync(?TABLE),
    _Timer = erlang:send_after(?SYNC_MS, self(), sync),
    {noreply, State};
handle_info(Unexpected, State) ->
    ?LOG_DEBUG("fw_snapshots_dets ignored a message: ~p", [Unexpected]),
    {noreply, State}.

-doc "A graceful shutdown is the one moment the file is guaranteed complete.".
-spec terminate(term(), []) -> ok.
terminate(_Reason, _State) -> survivable(dets:close(?TABLE), close).

%%% ---- internal ----

%% A disk that will not take a write loses durability, not the rooms. Killing a
%% live meeting because the volume filled up would be the worse failure, so the
%% error is logged and the room carries on in memory.
survivable(ok, _What) ->
    ok;
survivable({error, Reason}, What) ->
    ?LOG_WARNING("snapshot ~p failed: ~p", [What, Reason]),
    ok.

readable({Hash, Bytes}, Rooms) ->
    case fw_room:from_binary(Bytes) of
        {ok, Room} ->
            [{Hash, Room} | Rooms];
        {error, unreadable} ->
            ok = survivable(dets:delete(?TABLE, Hash), forget),
            Rooms
    end;
readable(_Malformed, Rooms) ->
    Rooms.
