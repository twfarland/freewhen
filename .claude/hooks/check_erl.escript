#!/usr/bin/env escript
%%! -sname fw_check_erl
%%
%% PostToolUse guard for .erl files under apps/*/src.
%%
%% Three checks, all of them things CI cannot catch as cheaply:
%%   1. module <= 200 lines, function <= 30 lines
%%   2. a module only calls modules in apps its own app may depend on
%%   3. a module does not call a facility its layer is forbidden
%%
%% The app dependency matrix is applied against a module index built by
%% globbing apps/*/src, so moving a module between apps updates the rules
%% automatically. Exit 2 reports the violations back to the caller.

-mode(compile).

-define(MAX_MODULE_LINES, 200).
-define(MAX_FUNCTION_LINES, 30).

main(_) ->
    ok = io:setopts(standard_io, [binary]),
    case target(json_stdin()) of
        skip -> halt(0);
        {check, Path} -> report(check(Path))
    end.

target(#{<<"tool_input">> := #{<<"file_path">> := Path}}) ->
    Norm = binary:replace(Path, <<"\\">>, <<"/">>, [global]),
    case {filename:extension(Norm), is_src(Norm)} of
        {<<".erl">>, true} -> {check, Norm};
        _ -> skip
    end;
target(_) ->
    skip.

is_src(Path) -> nomatch =/= binary:match(Path, <<"/apps/">>) andalso
                nomatch =/= binary:match(Path, <<"/src/">>).

report([]) -> halt(0);
report(Problems) ->
    io:format(standard_error, "~ts~n", [lists:join("\n", Problems)]),
    halt(2).

%%% ---- checks ----

check(Path) ->
    case file:read_file(Path) of
        {error, _} -> [];
        {ok, Source} ->
            Forms = forms(Source),
            size_problems(Path, Source, Forms) ++ layer_problems(Path, Source)
    end.

size_problems(Path, Source, Forms) ->
    Name = filename:basename(Path),
    Lines = length(binary:split(Source, <<"\n">>, [global])),
    Module = [io_lib:format("~ts is ~b lines (limit ~b). Split it by the noun it "
                            "owns, not by line count.", [Name, Lines, ?MAX_MODULE_LINES])
              || Lines > ?MAX_MODULE_LINES],
    Module ++ [io_lib:format("~ts:~b ~ts/~b is ~b lines (limit ~b). Name the stages "
                             "and let the caller read as a list of steps.",
                             [Name, Line, Fun, Arity, Span, ?MAX_FUNCTION_LINES])
               || {Fun, Arity, Line, Span} <- Forms, Span > ?MAX_FUNCTION_LINES].

layer_problems(Path, Source) ->
    App = app_of(Path),
    Calls = calls(Source),
    Index = module_index(),
    [Msg || {Mod, Fun} <- Calls, {bad, Msg} <- [judge(App, Mod, Fun, Index)]].

judge(App, Mod, Fun, Index) ->
    case maps:get(Mod, Index, external) of
        external -> external_rule(App, Mod, Fun);
        App -> ok;
        Other ->
            case lists:member(Other, may_depend_on(App)) of
                true -> ok;
                false -> {bad, io_lib:format("~ts may not call ~ts (~ts): the "
                                             "dependency between layers points the "
                                             "other way.", [App, Mod, Other])}
            end
    end.

%% Which apps each app is allowed to reach into. See docs/ARCHITECTURE.md.
may_depend_on(<<"fw_core">>) -> [];
may_depend_on(<<"fw_runtime">>) -> [<<"fw_core">>];
may_depend_on(<<"fw_web">>) -> [<<"fw_core">>, <<"fw_runtime">>];
may_depend_on(_) -> [].

%% Facilities a layer must not reach for, whatever app they live in.
external_rule(<<"fw_core">> = App, Mod, Fun) ->
    pure_rule(App, Mod, Fun, <<"fw_core is pure: take the value as an argument instead">>);
external_rule(<<"fw_runtime">>, <<"cowboy", _/binary>>, _) ->
    {bad, "fw_runtime may not mention cowboy: HTTP belongs to fw_web."};
external_rule(<<"fw_runtime">>, <<"json">>, _) ->
    {bad, "fw_runtime may not mention json: the wire projection belongs to fw_web."};
external_rule(_, _, _) ->
    ok.

pure_rule(App, Mod, Fun, Why) ->
    case impure_fun({Mod, Fun}) orelse impure_mod(App, Mod) of
        false -> ok;
        true -> {bad, io_lib:format("~ts:~ts is not available here — ~ts.", [Mod, Fun, Why])}
    end.

impure_fun(MF) ->
    lists:member(MF, [{<<"erlang">>, <<"system_time">>}, {<<"erlang">>, <<"monotonic_time">>},
                      {<<"erlang">>, <<"send_after">>}, {<<"erlang">>, <<"spawn">>},
                      {<<"erlang">>, <<"start_timer">>}, {<<"erlang">>, <<"self">>},
                      {<<"os">>, <<"timestamp">>}, {<<"os">>, <<"system_time">>},
                      {<<"os">>, <<"getenv">>}, {<<"application">>, <<"get_env">>},
                      {<<"crypto">>, <<"strong_rand_bytes">>}]).

impure_mod(_App, Mod) ->
    lists:member(Mod, [<<"gen_server">>, <<"gen_statem">>, <<"gen_event">>, <<"supervisor">>,
                       <<"ets">>, <<"dets">>, <<"file">>, <<"rand">>, <<"logger">>,
                       <<"timer">>, <<"json">>]).

%%% ---- source scanning ----

%% Token-level, so an -include_lib or an unexpanded macro cannot stop the check.
forms(Source) ->
    case erl_scan:string(binary_to_list(Source), 1, []) of
        {ok, Tokens, _} -> [F || F <- [form(T) || T <- split_forms(Tokens, [], [])], F =/= skip];
        {error, _, _} -> []
    end.

split_forms([], [], Acc) -> lists:reverse(Acc);
split_forms([], Cur, Acc) -> lists:reverse([lists:reverse(Cur) | Acc]);
split_forms([{dot, _} = D | Rest], Cur, Acc) ->
    split_forms(Rest, [], [lists:reverse([D | Cur]) | Acc]);
split_forms([T | Rest], Cur, Acc) ->
    split_forms(Rest, [T | Cur], Acc).

form([{atom, Line, Name}, {'(', _} | Args] = Tokens) ->
    {Name, arity(Args, 1, 0, false), Line, erl_scan:line(lists:last(Tokens)) - Line + 1};
form(_) ->
    skip.

%% Top-level commas between the opening paren and its match, plus one — except
%% for `f()`, which is why the "saw a token" flag exists.
arity([{')', _} | _], 1, _, false) -> 0;
arity([{')', _} | _], 1, N, true) -> N + 1;
arity([{',', _} | Rest], 1, N, _) -> arity(Rest, 1, N + 1, true);
arity([{Open, _} | Rest], D, N, _) when Open =:= '('; Open =:= '{'; Open =:= '[' ->
    arity(Rest, D + 1, N, true);
arity([{Close, _} | Rest], D, N, _) when Close =:= ')'; Close =:= '}'; Close =:= ']' ->
    arity(Rest, D - 1, N, true);
arity([_ | Rest], D, N, _) -> arity(Rest, D, N, true);
arity([], _, N, _) -> N.

%% Every Mod:Fun mentioned. Remote calls are the only cross-module edge that
%% matters here; imports are banned by the style guide anyway.
calls(Source) ->
    case erl_scan:string(binary_to_list(Source), 1, []) of
        {ok, Tokens, _} -> remote_calls(Tokens, []);
        {error, _, _} -> []
    end.

remote_calls([{atom, _, Mod}, {':', _}, {atom, _, Fun} | Rest], Acc) ->
    remote_calls(Rest, [{atom_to_binary(Mod), atom_to_binary(Fun)} | Acc]);
remote_calls([_ | Rest], Acc) -> remote_calls(Rest, Acc);
remote_calls([], Acc) -> lists:usort(Acc).

%%% ---- project layout ----

app_of(Path) ->
    case binary:split(Path, <<"/apps/">>) of
        [_, Rest] -> hd(binary:split(Rest, <<"/">>));
        _ -> <<"unknown">>
    end.

%% Recursive: modules are grouped into src/domain, src/ports and so on, and the
%% layer a module belongs to is its app, never its subdirectory.
module_index() ->
    maps:from_list(
        [{list_to_binary(filename:basename(F, ".erl")), list_to_binary(App)}
         || App <- apps(), F <- sources(App)]).

sources(App) ->
    filelib:wildcard("apps/" ++ App ++ "/src/*.erl") ++
        filelib:wildcard("apps/" ++ App ++ "/src/**/*.erl").

apps() ->
    [filename:basename(D) || D <- filelib:wildcard("apps/*"), filelib:is_dir(D)].

%%% ---- stdin ----

%% A payload we cannot read must never block an edit: skip instead.
json_stdin() ->
    try json:decode(read_all(<<>>)) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    catch
        _:_ -> #{}
    end.

read_all(Acc) ->
    case file:read(standard_io, 65536) of
        {ok, Data} -> read_all(<<Acc/binary, Data/binary>>);
        eof -> Acc;
        {error, _} -> Acc
    end.
