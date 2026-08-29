-module(fw_room_server).
-moduledoc """
One room, one process, all of it in memory.

No logic here: decode a command, call `fw_room`, keep the answer, tell the
watchers. Every rule lives in the domain, which is why nothing below branches
on room state. Watchers get `fw_room:t()` — the domain value, not JSON — so
this layer stays ignorant of the wire, and they are monitored so a connection
that goes away is forgotten without anyone saying so.

A room lives on idleness: the timer comes from `fw_room:expires_at/1`, which
every change pushes out, so the domain stays the single source of truth about
when a room ends. Picking a slot settles it and swaps the idle window for a
fixed grace — a settled room is no longer a negotiation.
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
%% write in the path of every cell of a drag and serialise every room through
%% one DETS process. A hard kill costs this much and no more; a graceful stop
%% flushes and costs nothing.
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
decide({submit, Id, FreeSlots}, Now, Room) ->
    changed(fw_room:submit(Id, FreeSlots, Now, Room));
decide({pick, Slot, Token}, Now, Room) ->
    changed(fw_room:pick(Slot, Token, Now, Room)).

changed({ok, Room}) -> {ok, ok, Room};
changed({error, Reason}) -> {error, Reason}.

published(#state{room = Room, watchers = Watchers} = State) ->
    _Sent = [Watcher ! {room_changed, Room} || Watcher <- maps:values(Watchers)],
    lifetime(State#state{unwritten = true}).

flushed(#state{unwritten = false} = State) ->
    State;
flushed(#state{unwritten = true} = State) ->
    ok = written(State),
    State#state{unwritten = false}.

written(#state{hash = Hash, room = Room, snapshots = Snapshots}) ->
    Snapshots:save(Hash, Room).

%%% ---- lifetime ----

%% A room lives on idleness, so every change moves its deadline; once a slot is
%% picked it stops being a negotiation and runs out a fixed grace instead.
lifetime(#state{phase = settled} = State) ->
    State;
lifetime(#state{room = Room, grace_ms = Grace} = State) ->
    case fw_room:picked(Room) of
        undefined -> deadline(fw_room:expires_at(Room) - fw_clock:now_ms(), State);
        _Slot -> (deadline(Grace, State))#state{phase = settled}
    end.

deadline(In, #state{timer = Timer} = State) ->
    _Cancelled = erlang:cancel_timer(Timer),
    State#state{timer = erlang:send_after(max(0, In), self(), expired)}.

-doc """
A room that ended on purpose leaves nothing behind; any other reason keeps the
snapshot. `normal` is expiry or a settled room past its grace. A shutdown is
the node going down for a release, and forgetting on that reason would erase
every room during exactly the event snapshots exist for.
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
