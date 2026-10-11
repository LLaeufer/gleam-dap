%% Thin wrapper over Erlang's `int` interpreter and its meta processes.
-module(gleam_dap_int_ffi).

-export([
    start/1, analyse/1, interpret/4, uninterpret/1, interpreted/0,
    set_break/2, delete_break/2, set_condition/3,
    auto_attach/1, on_attach/2, release/1,
    get_meta/1, continue/1, next/1, step/1, finish/1, stop/1,
    snapshot/0, status/1,
    backtrace/1, top_frame/1, frames/2, bindings/2,
    is_interpretable_module/1
]).

-define(TIMEOUT, 5000).

start(StackTrace) ->
    case application:ensure_all_started(debugger) of
        {ok, _} ->
            int:stack_trace(binary_to_atom(StackTrace, utf8)),
            {ok, nil};
        {error, Reason} ->
            {error, gleam_dap_ffi:format_term(Reason, 10)}
    end.

%% ---------------------------------------------------------------------------
%% Abstract code analysis
%%
%% Returns {ok, {Module, SourceFile, [FunctionInfo]}} where SourceFile is the
%% path from the module's `-file` attribute (relative to the package root
%% for Gleam modules) and FunctionInfo is
%% {function_info, Name, Arity, StartLine, EndLine, ClauseLines,
%%  BreakableLines, LinesWithFun, FunBodyLines} where FunBodyLines is
%% [{Line, Depth}] for statements inside anonymous functions, Depth being how
%% many anonymous functions they are nested in.

analyse(BeamPath) ->
    case beam_lib:chunks(binary_to_list(BeamPath), [abstract_code]) of
        {ok, {Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            File = case [F || {attribute, _, file, {F, _}} <- Forms] of
                [F | _] -> unicode:characters_to_binary(F);
                [] -> <<>>
            end,
            Functions = [analyse_function(F) || {function, _, _, _, _} = F <- Forms],
            {ok, {atom_to_binary(Mod, utf8), File, Functions}};
        {ok, {_Mod, [{abstract_code, no_abstract_code}]}} ->
            {error, <<"no debug info">>};
        {error, beam_lib, Reason} ->
            {error, gleam_dap_ffi:format_term(Reason, 10)};
        Other ->
            {error, gleam_dap_ffi:format_term(Other, 10)}
    end.

analyse_function({function, Anno, Name, Arity, Clauses}) ->
    Start = line(Anno),
    put(gleam_dap_breakable, []),
    put(gleam_dap_with_fun, []),
    put(gleam_dap_fun_body, []),
    put(gleam_dap_fun_depth, 0),
    put(gleam_dap_max, Start),
    ClauseLines = [clause_first_line(C) || C <- Clauses],
    walk(Clauses),
    Breakable = lists:usort(erase(gleam_dap_breakable)),
    WithFun = lists:usort(erase(gleam_dap_with_fun)),
    %% The innermost depth for lines shared by nested functions.
    FunBody = maps:to_list(lists:foldl(
        fun({L, D}, Acc) -> Acc#{L => max(D, maps:get(L, Acc, 0))} end,
        #{}, erase(gleam_dap_fun_body))),
    erase(gleam_dap_fun_depth),
    End = erase(gleam_dap_max),
    {function_info, atom_to_binary(Name, utf8), Arity, Start, End,
     [L || L <- ClauseLines, L > 0], Breakable, WithFun, FunBody}.

clause_first_line({clause, _, _, _, [First | _]}) -> line(element(2, First));
clause_first_line(_) -> 0.

walk({clause, A, Patterns, Guards, Body}) ->
    see(line(A)),
    walk(Patterns),
    walk(Guards),
    statements(Body);
walk({block, A, Body}) ->
    see(line(A)),
    statements(Body);
walk({'fun', A, {clauses, Clauses}}) ->
    see(line(A)),
    in_fun(Clauses);
walk({named_fun, A, _Name, Clauses}) ->
    see(line(A)),
    in_fun(Clauses);
walk({'try', A, Body, Clauses, Catches, After}) ->
    see(line(A)),
    statements(Body),
    walk(Clauses),
    walk(Catches),
    statements(After);
walk(T) when is_tuple(T), tuple_size(T) >= 2 ->
    case element(2, T) of
        A when is_integer(A); is_tuple(A); is_list(A) -> see(line(A));
        _ -> ok
    end,
    walk(tl(tuple_to_list(T)));
walk([H | T]) ->
    walk(H),
    walk(T);
walk(_) ->
    ok.

%% Walks the clauses of an anonymous function, recording their statement
%% lines as lines of a function body.
in_fun(Clauses) ->
    put(gleam_dap_fun_depth, get(gleam_dap_fun_depth) + 1),
    walk(Clauses),
    put(gleam_dap_fun_depth, get(gleam_dap_fun_depth) - 1).

statements(Body) ->
    lists:foreach(
        fun(Expr) ->
            L = line(element(2, Expr)),
            case L > 0 of
                true ->
                    put(gleam_dap_breakable, [L | get(gleam_dap_breakable)]),
                    case get(gleam_dap_fun_depth) of
                        0 -> ok;
                        Depth -> put(gleam_dap_fun_body, [{L, Depth} | get(gleam_dap_fun_body)])
                    end,
                    case contains_fun(Expr) of
                        true -> put(gleam_dap_with_fun, [L | get(gleam_dap_with_fun)]);
                        false -> ok
                    end;
                false -> ok
            end,
            walk(Expr)
        end,
        Body).

contains_fun({'fun', _, {clauses, _}}) -> true;
contains_fun({named_fun, _, _, _}) -> true;
contains_fun(T) when is_tuple(T) -> contains_fun(tuple_to_list(T));
contains_fun([H | T]) -> contains_fun(H) orelse contains_fun(T);
contains_fun(_) -> false.

see(L) when is_integer(L) ->
    case get(gleam_dap_max) of
        Max when L > Max -> put(gleam_dap_max, L);
        _ -> ok
    end;
see(_) -> ok.

line(A) ->
    try erl_anno:line(A) of
        L when is_integer(L) -> L;
        _ -> 0
    catch _:_ -> 0
    end.

%% ---------------------------------------------------------------------------
%% Interpreting

%% Gleam 1.19 BEAM files record no source, so `int:i(Module)` can't find
%% one. We pass the Gleam path explicitly.
interpret(Module, Source, BeamPath, Distributed) ->
    Mod = binary_to_atom(Module, utf8),
    case file:read_file(BeamPath) of
        {ok, Bin} ->
            _ = code:ensure_loaded(Mod),
            Abs = {Mod, binary_to_list(Source), binary_to_list(BeamPath), Bin},
            try case Distributed of true -> int:ni(Abs); false -> int:i(Abs) end of
                {module, Mod} -> {ok, nil};
                error -> {error, <<"int refused to interpret the module">>};
                Other -> {error, gleam_dap_ffi:format_term(Other, 10)}
            catch C:R -> {error, gleam_dap_ffi:format_term({C, R}, 10)}
            end;
        {error, R} -> {error, atom_to_binary(R, utf8)}
    end.

uninterpret(Module) ->
    catch int:n(binary_to_atom(Module, utf8)),
    nil.

interpreted() ->
    [atom_to_binary(M, utf8) || M <- int:interpreted()].

is_interpretable_module(Module) ->
    Mod = binary_to_atom(Module, utf8),
    not code:is_sticky(Mod).

%% ---------------------------------------------------------------------------
%% Breakpoints

set_break(Module, Line) ->
    _ = int:break(binary_to_atom(Module, utf8), Line),
    nil.

delete_break(Module, Line) ->
    _ = int:delete_break(binary_to_atom(Module, utf8), Line),
    nil.

%% Condition is {CheckModule, CheckFunction}, called by `int` with the
%% bindings.
set_condition(Module, Line, {M, F}) ->
    _ = int:test_at_break(binary_to_atom(Module, utf8), Line,
                          {binary_to_atom(M, utf8), binary_to_atom(F, utf8)}),
    nil.

%% ---------------------------------------------------------------------------
%% Stops
%%
%% Like ElixirLS, we never attach to processes that stop on a breakpoint:
%% `int` spawns `on_attach/2` on every stop, which only notifies the
%% session, so the meta process stays unattached and `auto_attach` keeps
%% firing. Processes that exit abnormally are attached so their last
%% bindings stay readable; `release/1` lets them go.

auto_attach(Callback) ->
    int:auto_attach([break, exit], {?MODULE, on_attach, [Callback]}),
    %% When attached, a running process can reach a breakpoint between
    %% `setBreakpoints` and `configurationDone`, before anyone listens.
    %% Report those now, or they stay stopped with nobody told.
    [on_attach(Pid, Callback) || {Pid, _, break, _} <- int:snapshot()],
    nil.

on_attach(Pid, Callback) ->
    case lists:keyfind(Pid, 1, int:snapshot()) of
        {Pid, _, break, {Mod, Line}} ->
            Callback({int_break, Pid, atom_to_binary(Mod, utf8), Line});
        {Pid, _, exit, Reason} when Reason =:= normal ->
            Callback({int_exit, Pid, Reason, none});
        {Pid, _, exit, Reason} ->
            case catch int:attached(Pid) of
                {ok, Meta} ->
                    Callback({int_exit, Pid, Reason, {some, {Meta, self()}}}),
                    hold();
                _ ->
                    Callback({int_exit, Pid, Reason, none})
            end;
        _ ->
            ok
    end.

hold() ->
    receive
        gleam_dap_release -> ok;
        _ -> hold()
    end.

release(Holder) ->
    Holder ! gleam_dap_release,
    nil.

get_meta(Pid) ->
    case catch dbg_iserver:safe_call({get_meta, Pid}) of
        {ok, Meta} when is_pid(Meta) -> {ok, Meta};
        _ -> {error, nil}
    end.

%% `int` can crash on internal pattern matches; ElixirLS falls back to
%% `continue` so the session never gets stuck. We do the same.
continue(Pid) -> command(Pid, fun int:continue/1).
next(Pid) -> command(Pid, fun int:next/1).
step(Pid) -> command(Pid, fun int:step/1).
finish(Pid) -> command(Pid, fun int:finish/1).

command(Pid, Fun) ->
    try Fun(Pid) of
        _ -> nil
    catch _:_ ->
        catch int:continue(Pid),
        nil
    end.

%% Pause: makes the interpreted process stop at its next expression.
stop(Pid) ->
    case get_meta(Pid) of
        {ok, Meta} -> int:meta(Meta, stop), {ok, nil};
        {error, nil} -> {error, nil}
    end.

%% [{Pid, Status, Module, Line}] for every interpreted process that is
%% alive. Module and Line are only meaningful when Status is `break`.
snapshot() ->
    lists:filtermap(
        fun({Pid, _Function, Status, Info}) ->
            case Status of
                exit -> false;
                break ->
                    {Mod, Line} = Info,
                    {true, {Pid, atom_to_binary(Status, utf8),
                            atom_to_binary(Mod, utf8), Line}};
                _ ->
                    {true, {Pid, atom_to_binary(Status, utf8), <<>>, 0}}
            end
        end,
        int:snapshot()).

status(Pid) ->
    case lists:keyfind(Pid, 1, int:snapshot()) of
        {Pid, _, Status, _} -> {ok, atom_to_binary(Status, utf8)};
        false -> {error, nil}
    end.

%% ---------------------------------------------------------------------------
%% Reading the stack. `int:meta/3` waits forever if the meta process doesn't
%% answer, so every call runs in a throwaway process with a timeout.

meta_call(Fun) ->
    case gleam_dap_ffi:run_with_timeout(Fun, ?TIMEOUT) of
        {ok, Result} -> {ok, Result};
        {error, _} = E -> E
    end.

%% [{Level, Module, Function, Arity}], innermost first.
backtrace(Meta) ->
    meta_call(fun() ->
        [frame_mfa(Le, MFA) || {Le, MFA} <- int:meta(Meta, backtrace, all)]
    end).

top_frame(Meta) ->
    meta_call(fun() ->
        case int:meta(Meta, backtrace, 1) of
            [{Le, MFA}] -> frame_mfa(Le, MFA);
            [] -> {0, <<>>, <<>>, 0}
        end
    end).

frame_mfa(Le, {M, F, As}) when is_list(As) ->
    {Le, atom_to_binary(M, utf8), atom_to_binary(F, utf8), length(As)};
frame_mfa(Le, {M, F, A}) when is_integer(A) ->
    {Le, atom_to_binary(M, utf8), atom_to_binary(F, utf8), A};
frame_mfa(Le, {Fun, As}) when is_function(Fun) ->
    {module, M} = erlang:fun_info(Fun, module),
    {name, N} = erlang:fun_info(Fun, name),
    {Le, atom_to_binary(M, utf8), atom_to_binary(N, utf8), length(As)}.

%% [{Level, Module, Function, Arity, Line}], innermost first, at most Limit
%% frames (0 for all). The line of
%% the innermost frame is not known here (it comes from the stop), so it is
%% returned as 0. Lines of outer frames come from `stack_frame` and are the
%% lines where each frame is currently executing a call.
frames(Meta, Limit) ->
    meta_call(fun() ->
        Backtrace = int:meta(Meta, backtrace, case Limit of 0 -> all; N -> N end),
        Lines = frame_lines(Meta, Backtrace),
        [begin
             {Le, M, F, A} = frame_mfa(Le0, MFA),
             {Le, M, F, A, maps:get(Le0, Lines, 0)}
         end || {Le0, MFA} <- Backtrace]
    end).

%% `stack_frame` crashes the meta process when asked for a frame below the
%% bottom of the stack, so only ask for levels the backtrace says exist.
frame_lines(Meta, Backtrace) ->
    Levels = [Le || {Le, _} <- Backtrace],
    frame_lines(Meta, Levels, #{}).

frame_lines(Meta, [SP, _Next | _] = Levels, Acc) ->
    case int:meta(Meta, stack_frame, {up, SP}) of
        {Le, {_Mod, Line}, _Bs} -> frame_lines(Meta, tl(Levels), Acc#{Le => Line});
        _ -> Acc
    end;
frame_lines(_Meta, _, Acc) ->
    Acc.

%% Bindings of the frame at level SP, or of the innermost frame for 0.
bindings(Meta, SP) ->
    meta_call(fun() ->
        Arg = case SP of 0 -> nostack; _ -> SP end,
        [{atom_to_binary(K, utf8), V} || {K, V} <- int:meta(Meta, bindings, Arg)]
    end).
