-module(fw_directory).
-moduledoc """
Which room hash is which process.

Reads go straight to a protected ETS table, so looking up a room costs no
message and does not serialise behind anything. Writes go through this process
because each one takes out a monitor: when a room dies — expired, finalised, or
crashed — its entry is removed by the `DOWN` that follows, rather than by
anyone remembering to.

The table holds hashes, which are secrets. It is `protected`, never dumped, and
never logged.
""".

-behaviour(gen_server).
-behaviour(fw_room_store).

-export([start_link/0, insert/2, find/1, count/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

-define(TABLE, ?MODULE).

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Fails rather than overwrites: a hash that is already taken is never reassigned.".
-spec insert(fw_room_store:hash(), pid()) -> ok | {error, collision}.
insert(Hash, Pid) -> gen_server:call(?MODULE, {insert, Hash, Pid}).

-spec find(fw_room_store:hash()) -> {ok, pid()} | error.
find(Hash) ->
    case ets:lookup(?TABLE, Hash) of
        [{_Hash, Pid}] -> {ok, Pid};
        [] -> error
    end.

-spec count() -> non_neg_integer().
count() ->
    case ets:info(?TABLE, size) of
        undefined -> 0;
        Size -> Size
    end.

%%% ---- gen_server ----

-spec init([]) -> {ok, #{reference() => fw_room_store:hash()}}.
init([]) ->
    _Table = ets:new(?TABLE, [named_table, protected, set, {read_concurrency, true}]),
    {ok, #{}}.

-spec handle_call({insert, fw_room_store:hash(), pid()}, gen_server:from(), State) ->
    {reply, ok | {error, collision}, State}
when
    State :: #{reference() => fw_room_store:hash()}.
handle_call({insert, Hash, Pid}, _From, Monitors) ->
    case ets:insert_new(?TABLE, {Hash, Pid}) of
        true -> {reply, ok, Monitors#{erlang:monitor(process, Pid) => Hash}};
        false -> {reply, {error, collision}, Monitors}
    end.

-spec handle_cast(term(), State) -> {noreply, State}.
handle_cast(Unexpected, Monitors) ->
    ?LOG_DEBUG("fw_directory ignored a cast: ~p", [tag(Unexpected)]),
    {noreply, Monitors}.

-spec handle_info(term(), State) -> {noreply, State} when
    State :: #{reference() => fw_room_store:hash()}.
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, Monitors) ->
    {noreply, drop(Monitor, Monitors)};
handle_info(Unexpected, Monitors) ->
    ?LOG_DEBUG("fw_directory ignored a message: ~p", [tag(Unexpected)]),
    {noreply, Monitors}.

%%% ---- internal ----

drop(Monitor, Monitors) ->
    case maps:take(Monitor, Monitors) of
        {Hash, Remaining} ->
            true = ets:delete(?TABLE, Hash),
            Remaining;
        error ->
            Monitors
    end.

%% Only the shape of an unexpected message is logged. Its contents could carry a
%% room hash, and nothing that identifies a room may reach the log.
tag(Message) when is_tuple(Message), tuple_size(Message) > 0 -> element(1, Message);
tag(Message) when is_atom(Message) -> Message;
tag(_Message) -> unknown.
