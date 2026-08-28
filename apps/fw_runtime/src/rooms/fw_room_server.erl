-module(fw_room_server).
-moduledoc """
One room, one process, all of it in memory.

The process holds no logic: it decodes a command, calls `fw_room`, keeps the
answer, and tells its watchers. Every rule about what is allowed lives in the
domain, which is why this module has no branch on room state anywhere.

It does not know its own hash. The directory owns that mapping, so a room
process contains nothing that could identify the room to anyone who obtained a
process dump.

Watchers are monitored, so a connection that goes away is forgotten without
anyone having to say so. The payload they receive is `fw_room:t()` — the
domain value, not JSON — which is what keeps this layer ignorant of the wire.

Lifetime is the room's own: the TTL timer is set from `fw_room:expires_at/1`,
so the domain remains the single source of truth about when a room ends. Once a
slot is picked the room stops accepting changes and the timer is shortened to a
grace period, long enough to export the invitation and short enough that a
settled room is not a resident.
""".

-behaviour(gen_server).

-export([start_link/1, watch/2, command/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([args/0, command/0, result/0]).

-include_lib("kernel/include/logger.hrl").

-type args() :: #{
    hash := fw_room_store:hash(),
    room := fw_room:t(),
    grace_ms := pos_integer(),
    snapshots := module()
}.

-type command() ::
    {join, fw_attendee:alias()}
    | {submit, fw_attendee:id(), [fw_grid:slot()]}
    | {leave, fw_attendee:id()}
    | {pick, fw_grid:slot(), fw_room:token()}.

-type result() :: ok | {joined, fw_attendee:id()}.

-record(state, {
    hash :: fw_room_store:hash(),
    room :: fw_room:t(),
    watchers :: #{reference() => pid()},
    timer :: reference(),
    grace_ms :: pos_integer(),
    snapshots :: module(),
    unwritten :: boolean(),
    phase :: live | settled
}).

%% How long a change may go unwritten. Writing on every change would put a disk
%% write in the path of every keystroke of a drag, and serialise every room in
%% the system through one DETS process; a hard kill can cost this much and no
%% more, and a graceful stop costs nothing because it flushes.
-define(SNAPSHOT_EVERY_MS, 2_000).

-spec start_link(args()) -> gen_server:start_ret().
start_link(Args) -> gen_server:start_link(?MODULE, Args, []).

-doc """
Subscribe and read in one step, so a watcher cannot miss a change between the
two. Afterwards the room sends `{room_changed, fw_room:t()}` on every change.
""".
-spec watch(pid(), pid()) -> {ok, fw_room:t()}.
watch(Room, Watcher) -> gen_server:call(Room, {watch, Watcher}).

-spec command(pid(), command()) -> {ok, result()} | {error, fw_room:error()}.
command(Room, Command) -> gen_server:call(Room, {command, Command}).

%%% ---- gen_server ----

-spec init(args()) -> {ok, #state{}}.
init(#{hash := Hash, room := Room, grace_ms := Grace, snapshots := Snapshots}) ->
    _Trap = process_flag(trap_exit, true),
    Remaining = max(0, fw_room:expires_at(Room) - fw_clock:now_ms()),
    State = #state{
        hash = Hash,
        room = Room,
        watchers = #{},
        timer = erlang:send_after(Remaining, self(), expired),
        grace_ms = Grace,
        snapshots = Snapshots,
        unwritten = false,
        phase = live
    },
    %% Written immediately, not on first change: a room nobody has touched yet
    %% is still a room, and losing it to a release would be the same failure.
    ok = written(State),
    _Timer = erlang:send_after(?SNAPSHOT_EVERY_MS, self(), snapshot),
    {ok, State}.

-spec handle_call({watch, pid()}, gen_server:from(), #state{}) ->
                     {reply, {ok, fw_room:t()}, #state{}};
                 ({command, command()}, gen_server:from(), #state{}) ->
                     {reply, {ok, result()} | {error, fw_room:error()}, #state{}}.
handle_call({watch, Watcher}, _From, #state{room = Room, watchers = Watchers} = State) ->
    Monitor = erlang:monitor(process, Watcher),
    {reply, {ok, Room}, State#state{watchers = Watchers#{Monitor => Watcher}}};
handle_call({command, Command}, _From, State) ->
    {Reply, Next} = run(Command, State),
    {reply, Reply, Next}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Unexpected, State) ->
    ?LOG_DEBUG("room ignored a cast: ~p", [tag(Unexpected)]),
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, normal, #state{}}.
handle_info(expired, State) ->
    {stop, normal, State};
handle_info(snapshot, State) ->
    _Timer = erlang:send_after(?SNAPSHOT_EVERY_MS, self(), snapshot),
    {noreply, flushed(State)};
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, #state{watchers = Watchers} = State) ->
    {noreply, State#state{watchers = maps:remove(Monitor, Watchers)}};
handle_info(Unexpected, State) ->
    ?LOG_DEBUG("room ignored a message: ~p", [tag(Unexpected)]),
    {noreply, State}.

%%% ---- commands ----

run(Command, #state{room = Room} = State) ->
    case decide(Command, fw_clock:now_ms(), Room) of
        {ok, Result, Updated} -> {{ok, Result}, published(State#state{room = Updated})};
        {error, Reason} -> {{error, Reason}, State}
    end.

decide({join, Alias}, Now, Room) ->
    Id = fw_ids:attendee_id(),
    case fw_room:join(Id, Alias, Now, Room) of
        {ok, Updated} -> {ok, {joined, Id}, Updated};
        {error, Reason} -> {error, Reason}
    end;
decide({submit, Id, BusySlots}, Now, Room) ->
    changed(fw_room:submit(Id, BusySlots, Now, Room));
decide({leave, Id}, _Now, Room) ->
    {ok, ok, fw_room:leave(Id, Room)};
decide({pick, Slot, Token}, Now, Room) ->
    changed(fw_room:pick(Slot, Token, Now, Room)).

changed({ok, Room}) -> {ok, ok, Room};
changed({error, Reason}) -> {error, Reason}.

published(#state{room = Room, watchers = Watchers} = State) ->
    _Sent = [Watcher ! {room_changed, Room} || Watcher <- maps:values(Watchers)],
    settle(State#state{unwritten = true}).

flushed(#state{unwritten = false} = State) ->
    State;
flushed(#state{unwritten = true} = State) ->
    ok = written(State),
    State#state{unwritten = false}.

written(#state{hash = Hash, room = Room, snapshots = Snapshots}) ->
    Snapshots:save(Hash, Room).

%%% ---- lifetime ----

settle(#state{phase = settled} = State) ->
    State;
settle(#state{room = Room} = State) ->
    case fw_room:picked(Room) of
        undefined -> State;
        _Slot -> grace(State)
    end.

grace(#state{timer = Timer, grace_ms = Grace} = State) ->
    _Cancelled = erlang:cancel_timer(Timer),
    State#state{phase = settled, timer = erlang:send_after(Grace, self(), expired)}.

-doc """
A room that ended on purpose leaves nothing behind, on disk or anywhere else.

Any other reason keeps the snapshot, and the distinction is the whole point:
`normal` is expiry or a settled room past its grace, while a shutdown is the
node going down for a release and a crash is a room we would rather have back.
Forgetting on every reason would erase every room during exactly the event
snapshots exist for.
""".
-spec terminate(term(), #state{}) -> ok.
terminate(normal, #state{hash = Hash, snapshots = Snapshots}) ->
    Snapshots:forget(Hash);
terminate(_NotOurDoing, State) ->
    _Flushed = flushed(State),
    ok.

%% Only the shape of an unexpected message is logged: its contents could carry
%% a room hash, and nothing identifying a room may reach the log.
tag(Message) when is_tuple(Message), tuple_size(Message) > 0 -> element(1, Message);
tag(Message) when is_atom(Message) -> Message;
tag(_Message) -> unknown.
