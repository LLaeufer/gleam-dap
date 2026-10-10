%% Runtime helpers for gleam-dap that are easier to write in Erlang:
%% stdio transport, JSON, output capture, term inspection, processes and
%% a shared reference table for DAP ids.
-module(gleam_dap_ffi).

-export([
    stdio_start/2, write/1, next_seq/0,
    json_encode/1, json_decode/1,
    refs_init/0, refs_put/1, refs_get/1, refs_clear/0, refs_clear_for/1,
    watch_process/2, descendants/1,
    start_output/2, capture_stdio/2,
    run_command/4, find_executable/1,
    classify/1, format_term/2, to_dynamic/1,
    spawn_program/4, process_parent/1, process_alive/1, kill/1,
    process_name/1, all_processes/0, pid_to_string/1,
    log_open/1, log/1,
    otp_release/0, halt/1, set_cwd/1, get_cwd/0, put_env/2,
    send_after/2, unique_name/0,
    read_file/1, list_dir/1, wildcard/1, absname/1, run_with_timeout/2
]).

%% ---------------------------------------------------------------------------
%% Stdio transport
%%
%% The adapter VM is started with `-noinput`, so nothing else reads stdin.
%% We open file descriptors 0 and 1 as a port. Program output never reaches
%% fd 1 because `capture_stdio/2` replaces the `user` I/O server.

stdio_start(OnMessage, OnEof) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        Port = open_port({fd, 0, 1}, [binary, stream, eof]),
        persistent_term:put(gleam_dap_out, Port),
        Parent ! {gleam_dap_stdio_ready, self()},
        stdio_loop(Port, <<>>, OnMessage, OnEof)
    end),
    receive {gleam_dap_stdio_ready, Pid} -> nil end.

stdio_loop(Port, Buffer, OnMessage, OnEof) ->
    receive
        {Port, {data, Data}} ->
            {Messages, Rest} =
                'gleam_dap@dap@framing':parse(<<Buffer/binary, Data/binary>>),
            lists:foreach(OnMessage, Messages),
            stdio_loop(Port, Rest, OnMessage, OnEof);
        {Port, eof} ->
            OnEof(),
            ok
    end.

write(Bytes) ->
    case persistent_term:get(gleam_dap_out, undefined) of
        undefined -> nil;
        Port ->
            try port_command(Port, Bytes) catch _:_ -> ok end,
            nil
    end.

next_seq() ->
    Ref = case persistent_term:get(gleam_dap_seq, undefined) of
        undefined ->
            R = atomics:new(1, []),
            persistent_term:put(gleam_dap_seq, R),
            R;
        R -> R
    end,
    atomics:add_get(Ref, 1, 1).

%% ---------------------------------------------------------------------------
%% JSON, through OTP 27's `json` module.

json_encode(Json) ->
    iolist_to_binary(json:encode(to_json_term(Json))).

to_json_term(j_null) -> null;
to_json_term({j_bool, B}) -> B;
to_json_term({j_int, I}) -> I;
to_json_term({j_float, F}) -> F;
to_json_term({j_string, S}) -> S;
to_json_term({j_array, L}) -> [to_json_term(X) || X <- L];
to_json_term({j_object, Pairs}) ->
    maps:from_list([{K, to_json_term(V)} || {K, V} <- Pairs]).

json_decode(Bin) ->
    try {ok, json:decode(Bin)}
    catch _:_ -> {error, nil}
    end.

%% ---------------------------------------------------------------------------
%% Reference table: DAP frame ids and variable references point at terms
%% stored here. Public so workers outside the session can add entries.

refs_init() ->
    case ets:info(gleam_dap_refs) of
        undefined ->
            ets:new(gleam_dap_refs, [named_table, public, set]),
            ets:insert(gleam_dap_refs, {counter, 0});
        _ -> ok
    end,
    nil.

refs_put(Term) ->
    Id = ets:update_counter(gleam_dap_refs, counter, 1),
    ets:insert(gleam_dap_refs, {Id, Term}),
    Id.

refs_get(Id) ->
    case ets:lookup(gleam_dap_refs, Id) of
        [{Id, Term}] -> {ok, Term};
        [] -> {error, nil}
    end.

%% Ids keep increasing so a stale id from the client never points at a new
%% entry.
refs_clear() ->
    [{counter, N}] = ets:lookup(gleam_dap_refs, counter),
    ets:delete_all_objects(gleam_dap_refs),
    ets:insert(gleam_dap_refs, {counter, N}),
    nil.

%% Drops the entries that belong to one process (element 2 of the entry).
refs_clear_for(Pid) ->
    ets:select_delete(gleam_dap_refs,
                      [{{'_', '$1'},
                        [{is_tuple, '$1'}, {'>=', {size, '$1'}, 2},
                         {'=:=', {element, 2, '$1'}, Pid}],
                        [true]}]),
    nil.

%% ---------------------------------------------------------------------------
%% Output capture: a minimal I/O server that forwards everything written to
%% it to a callback, used as group leader for the debugged program.

start_output(Category, OnOutput) ->
    spawn(fun() -> output_loop(Category, OnOutput) end).

output_loop(Category, OnOutput) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            Reply = io_request(Request, Category, OnOutput),
            From ! {io_reply, ReplyAs, Reply},
            output_loop(Category, OnOutput);
        _ ->
            output_loop(Category, OnOutput)
    end.

io_request({put_chars, Encoding, Chars}, Category, OnOutput) ->
    emit(Category, OnOutput, unicode:characters_to_binary(Chars, Encoding));
io_request({put_chars, Encoding, M, F, A}, Category, OnOutput) ->
    try apply(M, F, A) of
        Chars -> emit(Category, OnOutput, unicode:characters_to_binary(Chars, Encoding))
    catch _:_ -> {error, put_chars}
    end;
io_request({put_chars, Chars}, Category, OnOutput) ->
    io_request({put_chars, latin1, Chars}, Category, OnOutput);
io_request({put_chars, M, F, A}, Category, OnOutput) ->
    io_request({put_chars, latin1, M, F, A}, Category, OnOutput);
io_request({requests, Requests}, Category, OnOutput) ->
    lists:foldl(fun(R, ok) -> io_request(R, Category, OnOutput);
                   (_, Error) -> Error
                end, ok, Requests);
io_request(getopts, _, _) -> [binary, {encoding, unicode}];
io_request({setopts, _}, _, _) -> ok;
io_request({get_geometry, _}, _, _) -> {error, enotsup};
io_request({get_chars, _, _, _}, _, _) -> eof;
io_request({get_chars, _, _}, _, _) -> eof;
io_request({get_line, _, _}, _, _) -> eof;
io_request({get_line, _}, _, _) -> eof;
io_request({get_until, _, _, _, _, _}, _, _) -> eof;
io_request({get_until, _, _, _, _}, _, _) -> eof;
io_request(_, _, _) -> {error, request}.

emit(Category, OnOutput, Bin) when is_binary(Bin) ->
    OnOutput(Category, Bin),
    ok;
emit(_, _, _) ->
    {error, put_chars}.

%% Replace `user` and `standard_error` with the capture servers and move
%% every process that writes to the real terminal over to them, so nothing
%% but DAP messages reaches fd 1.
capture_stdio(Stdout, Stderr) ->
    OldUser = whereis(user),
    swap_registration(user, Stdout),
    swap_registration(standard_error, Stderr),
    lists:foreach(
        fun(P) ->
            case process_info(P, group_leader) of
                {group_leader, OldUser} when P =/= OldUser ->
                    catch group_leader(Stdout, P);
                _ -> ok
            end
        end,
        processes()),
    nil.

swap_registration(Name, Pid) ->
    case whereis(Name) of
        undefined -> ok;
        Old ->
            catch unregister(Name),
            catch register(list_to_atom("gleam_dap_raw_" ++ atom_to_list(Name)), Old)
    end,
    register(Name, Pid).

%% ---------------------------------------------------------------------------
%% External commands

find_executable(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

run_command(Executable, Args, Cwd, Env) ->
    try
        Port = open_port(
            {spawn_executable, binary_to_list(Executable)},
            [{args, [binary_to_list(A) || A <- Args]},
             {cd, binary_to_list(Cwd)},
             {env, [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Env]},
             exit_status, stderr_to_stdout, binary, hide]),
        {ok, collect(Port, [])}
    catch
        _:Reason -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, [Acc, D]);
        {Port, {exit_status, S}} -> {S, iolist_to_binary(Acc)}
    end.

%% ---------------------------------------------------------------------------
%% Term inspection. Returns values of the Gleam type `gleam_dap/value.Term`.

classify(T) when is_integer(T) -> {t_int, T};
classify(T) when is_float(T) -> {t_float, T};
classify(T) when is_atom(T) -> {t_atom, atom_to_binary(T, utf8)};
classify(T) when is_binary(T) -> {t_binary, T};
classify(T) when is_bitstring(T) -> {t_bitstring, T, bit_size(T)};
classify(T) when is_list(T) ->
    case improper(T, []) of
        {proper, L} -> {t_list, L};
        {improper, L, Tail} -> {t_improper_list, L, Tail}
    end;
classify(T) when is_tuple(T) -> {t_tuple, tuple_to_list(T)};
classify(T) when is_map(T) -> {t_map, maps:to_list(T)};
classify(T) when is_function(T) ->
    Info = erlang:fun_info(T),
    {module, M} = lists:keyfind(module, 1, Info),
    {name, N} = lists:keyfind(name, 1, Info),
    {arity, A} = lists:keyfind(arity, 1, Info),
    {type, Type} = lists:keyfind(type, 1, Info),
    {t_function, atom_to_binary(M, utf8), atom_to_binary(N, utf8), A, Type =:= local};
classify(T) when is_pid(T) -> {t_pid, list_to_binary(pid_to_list(T))};
classify(T) when is_reference(T) -> {t_reference, list_to_binary(ref_to_list(T))};
classify(T) when is_port(T) -> {t_port, list_to_binary(port_to_list(T))};
classify(T) -> {t_other, format_term(T, 20)}.

improper([], Acc) -> {proper, lists:reverse(Acc)};
improper([H | T], Acc) -> improper(T, [H | Acc]);
improper(Tail, Acc) -> {improper, lists:reverse(Acc), Tail}.

format_term(Term, Depth) ->
    unicode:characters_to_binary(io_lib:format("~0tP", [Term, Depth])).

to_dynamic(X) -> X.

%% ---------------------------------------------------------------------------
%% Processes

%% Starts the program's entry function in a fresh process whose group leader
%% is the output capture server.
spawn_program(Module, Function, Args, GroupLeader) ->
    spawn(fun() ->
        group_leader(GroupLeader, self()),
        apply(binary_to_atom(Module, utf8), binary_to_atom(Function, utf8), Args)
    end).

process_parent(Pid) ->
    try process_info(Pid, parent) of
        {parent, P} when is_pid(P) -> {ok, P};
        _ -> {error, nil}
    catch _:_ -> {error, nil}
    end.

process_alive(Pid) -> is_process_alive(Pid).

%% Calls OnDown(Reason) when Pid exits.
watch_process(Pid, OnDown) ->
    spawn(fun() ->
        Ref = erlang:monitor(process, Pid),
        receive {'DOWN', Ref, process, Pid, Reason} -> OnDown(Reason) end
    end),
    nil.

%% Live processes whose parent chain leads to Root, Root included.
%% The interpreter's own processes are left out.
descendants(Root) ->
    [P || P <- processes(), descends(P, Root, 50), not is_debugger_process(P)].

is_debugger_process(P) ->
    case catch process_info(P, current_function) of
        {current_function, {M, _, _}} ->
            lists:prefix("dbg_", atom_to_list(M));
        _ -> false
    end.

descends(Root, Root, _) -> true;
descends(_, _, 0) -> false;
descends(P, Root, N) ->
    case process_parent(P) of
        {ok, Parent} -> descends(Parent, Root, N - 1);
        {error, nil} -> false
    end.

kill(Pid) -> exit(Pid, kill), nil.

process_name(Pid) ->
    case catch process_info(Pid, [registered_name, dictionary, initial_call]) of
        [{registered_name, Name}, _, _] when is_atom(Name), Name =/= [] ->
            {ok, atom_to_binary(Name, utf8)};
        [_, {dictionary, Dict}, {initial_call, Initial}] ->
            case lists:keyfind('$process_label', 1, Dict) of
                {_, Label} -> {ok, format_term(Label, 5)};
                false ->
                    case lists:keyfind('$initial_call', 1, Dict) of
                        {_, {M, F, A}} -> {ok, mfa_name(M, F, A)};
                        false ->
                            case Initial of
                                {erlang, apply, 2} -> {error, nil};
                                {M, F, A} -> {ok, mfa_name(M, F, A)};
                                _ -> {error, nil}
                            end
                    end
            end;
        _ -> {error, nil}
    end.

mfa_name(M, F, A) ->
    unicode:characters_to_binary(io_lib:format("~ts:~ts/~p", [M, F, A])).

all_processes() -> processes().

pid_to_string(Pid) -> list_to_binary(pid_to_list(Pid)).

send_after(Ms, Fun) ->
    spawn(fun() -> receive after Ms -> Fun() end end),
    nil.

unique_name() ->
    integer_to_binary(erlang:unique_integer([positive])).

%% Runs Fun in a separate process and waits at most Timeout milliseconds.
run_with_timeout(Fun, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() -> Self ! {Ref, Fun()} end),
    receive
        {Ref, Result} ->
            erlang:demonitor(Mon, [flush]),
            {ok, Result};
        {'DOWN', Mon, process, Pid, Reason} ->
            {error, format_term(Reason, 10)}
    after Timeout ->
        exit(Pid, kill),
        erlang:demonitor(Mon, [flush]),
        {error, <<"timeout">>}
    end.

%% ---------------------------------------------------------------------------
%% Logging to a file, never to stdout.

log_open(Path) ->
    case file:open(Path, [append, binary]) of
        {ok, Fd} -> persistent_term:put(gleam_dap_log, Fd), nil;
        _ -> nil
    end.

log(Line) ->
    case persistent_term:get(gleam_dap_log, undefined) of
        undefined -> nil;
        Fd ->
            {{Y, Mo, D}, {H, Mi, S}} = calendar:local_time(),
            Stamp = io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B ",
                                  [Y, Mo, D, H, Mi, S]),
            _ = file:write(Fd, [Stamp, Line, $\n]),
            nil
    end.

%% ---------------------------------------------------------------------------
%% System

otp_release() ->
    list_to_integer(erlang:system_info(otp_release)).

halt(Code) -> erlang:halt(Code).

set_cwd(Dir) ->
    case file:set_cwd(Dir) of
        ok -> {ok, nil};
        {error, R} -> {error, atom_to_binary(R, utf8)}
    end.

get_cwd() ->
    {ok, Dir} = file:get_cwd(),
    unicode:characters_to_binary(Dir).

put_env(Key, Value) ->
    os:putenv(binary_to_list(Key), binary_to_list(Value)),
    nil.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

list_dir(Path) ->
    case file:list_dir(Path) of
        {ok, Names} -> {ok, [unicode:characters_to_binary(N) || N <- lists:sort(Names)]};
        {error, _} -> {error, nil}
    end.

wildcard(Pattern) ->
    [unicode:characters_to_binary(P) || P <- lists:sort(filelib:wildcard(binary_to_list(Pattern)))].

absname(Path) ->
    unicode:characters_to_binary(normalise(filename:absname(Path))).

normalise(Path) ->
    [Root | Parts] = filename:split(Path),
    filename:join([Root | lists:reverse(lists:foldl(
        fun(".", Acc) -> Acc;
           ("..", [_ | Acc]) -> Acc;
           ("..", []) -> [];
           (P, Acc) -> [P | Acc]
        end, [], [unicode:characters_to_list(P) || P <- Parts]))]).
