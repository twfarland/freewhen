-module(fw_limiter).
-moduledoc """
Rate limiting for room creation, one token bucket per caller.

Creating a room costs memory that lives as long as the room does, so this is
the one endpoint
where an unauthenticated stranger can make the server hold something. The
bucket is what stops a loop from turning that into an outage.

Buckets are swept once a minute. Without that, the limiter itself becomes the
memory-exhaustion vector it exists to prevent: an attacker rotating source
addresses would mint an unbounded number of buckets, each smaller than a room
but no less unbounded. An entry idle for longer than it takes to refill
completely is indistinguishable from a caller who never arrived, so it is
dropped.
""".

-behaviour(gen_server).

-export([start_link/0, allow/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

-define(TABLE, ?MODULE).
-define(SWEEP_MS, 60_000).

-record(state, {config :: fw_bucket:config(), idle_ms :: pos_integer()}).

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Spend one request's worth of allowance for `Key`, or refuse.".
-spec allow(binary()) -> allowed | denied.
allow(Key) -> gen_server:call(?MODULE, {allow, Key}).

%%% ---- gen_server ----

-spec init([]) -> {ok, #state{}}.
init([]) ->
    _Table = ets:new(?TABLE, [named_table, private, set]),
    Config = maps:get(create_bucket, fw_settings:get()),
    _Timer = erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #state{config = Config, idle_ms = idle_ms(Config)}}.

-spec handle_call({allow, binary()}, gen_server:from(), #state{}) ->
    {reply, allowed | denied, #state{}}.
handle_call({allow, Key}, _From, #state{config = Config} = State) ->
    Now = fw_clock:now_ms(),
    #{cost := Cost} = Config,
    {Verdict, Bucket} = spend(Cost, Now, bucket(Key, Config, Now)),
    true = ets:insert(?TABLE, {Key, Bucket, Now}),
    {reply, Verdict, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Unexpected, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(sweep, #state{idle_ms = Idle} = State) ->
    _Dropped = ets:select_delete(?TABLE, stale(fw_clock:now_ms() - Idle)),
    _Timer = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(Unexpected, State) ->
    ?LOG_DEBUG("fw_limiter ignored a message: ~p", [Unexpected]),
    {noreply, State}.

%%% ---- internal ----

spend(Cost, Now, Bucket) ->
    case fw_bucket:take(Cost, Now, Bucket) of
        {ok, Spent} -> {allowed, Spent};
        {denied, Unchanged} -> {denied, Unchanged}
    end.

bucket(Key, Config, Now) ->
    case ets:lookup(?TABLE, Key) of
        [{_Key, Bucket, _At}] -> Bucket;
        [] -> fw_bucket:new(Config, Now)
    end.

stale(Before) -> [{{'_', '_', '$1'}, [{'<', '$1', Before}], [true]}].

%% Long enough that a swept bucket would have refilled to full anyway, so
%% sweeping can never hand an attacker allowance they had not already earned.
idle_ms(#{capacity := Capacity, refill_per_sec := Rate}) ->
    max(?SWEEP_MS, round(Capacity / Rate * 1000)).
