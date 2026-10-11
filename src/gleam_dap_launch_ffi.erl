-module(gleam_dap_launch_ffi).
-export([loaded_elsewhere/2, parallel_map/2, eunit_args/1, connect_node/2,
         start_distribution/0, module_exports/1, get_env/1,
         wait_for_debugger_server/0]).

%% True when the module the adapter would get is not the project's copy:
%% either the adapter has already loaded its own, or its own comes first
%% in the code path.
loaded_elsewhere(Module, ProjectDir) ->
    Mod = binary_to_atom(Module, utf8),
    Dir = binary_to_list(ProjectDir),
    Path = case code:is_loaded(Mod) of
        {file, P} when is_list(P) -> P;
        {file, _} -> preloaded;
        false -> code:which(Mod)
    end,
    case Path of
        P2 when is_list(P2) ->
            Inside = <<(gleam_dap_ffi:absname(Dir))/binary, "/">>,
            string:prefix(gleam_dap_ffi:absname(P2), Inside) =:= nomatch;
        non_existing -> false;
        _ -> true
    end.

parallel_map(Items, Fun) ->
    Self = self(),
    Refs = [begin
                Ref = make_ref(),
                spawn_link(fun() -> Self ! {Ref, Fun(Item)} end),
                Ref
            end || Item <- Items],
    [receive {Ref, Result} -> Result end || Ref <- Refs].

eunit_args(Modules) ->
    [[binary_to_atom(M, utf8) || M <- Modules], [verbose]].

%% Starts distribution for attach, with a random short name.
start_distribution() ->
    case node() of
        nonode@nohost ->
            %% The OS pid keeps two adapters started together apart.
            Name = list_to_atom("gleam_dap_" ++ os:getpid() ++ "_"
                                ++ integer_to_list(erlang:unique_integer([positive]))),
            NameType = case net_kernel:start(Name, #{name_domain => shortnames}) of
                {ok, _} -> ok;
                {error, _} ->
                    case net_kernel:start(Name, #{name_domain => longnames}) of
                        {ok, _} -> ok;
                        {error, R} -> {error, R}
                    end
            end,
            case NameType of
                ok -> {ok, nil};
                {error, Reason} -> {error, gleam_dap_ffi:format_term(Reason, 10)}
            end;
        _ -> {ok, nil}
    end.

connect_node(Node, Cookie) ->
    NodeAtom = binary_to_atom(Node, utf8),
    case start_distribution() of
        {ok, nil} ->
            case Cookie of
                <<>> -> ok;
                _ -> erlang:set_cookie(NodeAtom, binary_to_atom(Cookie, utf8))
            end,
            case net_kernel:connect_node(NodeAtom) of
                true -> {ok, nil};
                _ -> {error, <<"Could not connect to node ", Node/binary>>}
            end;
        Error -> Error
    end.

%% Read from the BEAM file: calling module_info on an interpreted module
%% while a process is paused can deadlock (ElixirLS issue #940).
module_exports(Module) ->
    Mod = binary_to_atom(Module, utf8),
    case code:which(Mod) of
        Path when is_list(Path) ->
            case beam_lib:chunks(Path, [exports]) of
                {ok, {_, [{exports, Exports}]}} ->
                    lists:usort([{atom_to_binary(F, utf8), A} || {F, A} <- Exports,
                                                                 F =/= module_info]);
                _ -> []
            end;
        _ -> []
    end.

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% `int` registers its server as a global name, and the interpreted stubs
%% on other nodes look it up there. Until the name has reached a node, a
%% process there that calls an interpreted function crashes, so wait for it
%% before interpreting anything (up to five seconds).
wait_for_debugger_server() ->
    catch global:sync(),
    wait_for_debugger_server(50).

wait_for_debugger_server(0) -> nil;
wait_for_debugger_server(N) ->
    Missing = [Node || Node <- nodes(),
                       catch erpc:call(Node, global, whereis_name, [dbg_iserver], 1000)
                           =:= undefined],
    case Missing of
        [] -> nil;
        _ -> timer:sleep(100), wait_for_debugger_server(N - 1)
    end.
