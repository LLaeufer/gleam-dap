-module(test_ffi).
-export([to_dynamic/1, make_pid/0, make_fun/0, bits/0, improper/0, map/0,
         write_file/2, get_env/1, start_target/1, stop_target/2]).

to_dynamic(X) -> X.
make_pid() -> list_to_pid("<0.42.0>").
make_fun() -> fun lists:map/2.
bits() -> <<1:3>>.
improper() -> [1 | 2].
map() -> #{<<"a">> => 1}.
write_file(Path, Bin) -> ok = file:write_file(Path, Bin), nil.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        V -> {ok, list_to_binary(V)}
    end.

%% Starts the fixture in a separate node that the adapter can attach to.
%% Returns the node name.
start_target(Cookie) ->
    {ok, Cwd} = file:get_cwd(),
    Ebins = filelib:wildcard(filename:join(Cwd, "fixtures/sample/build/dev/erlang/*/ebin")),
    Name = "gleam_dap_target_" ++ integer_to_list(erlang:unique_integer([positive])),
    {ok, Host} = inet:gethostname(),
    Port = open_port({spawn_executable, os:find_executable("erl")},
                     [{args, ["-sname", Name, "-setcookie", binary_to_list(Cookie),
                              "-noinput", "-pa" | Ebins] ++ ["-eval", "sample:serve_main()"]},
                      exit_status]),
    persistent_term:put({test_target, Name}, Port),
    timer:sleep(1500),
    list_to_binary(Name ++ "@" ++ Host).

%% Asks the node for its interpreted modules, then stops it.
stop_target(Node, Cookie) ->
    NodeAtom = binary_to_atom(Node, utf8),
    case node() of
        nonode@nohost ->
            {ok, _} = net_kernel:start(list_to_atom("gleam_dap_probe_" ++
                          integer_to_list(erlang:unique_integer([positive]))),
                          #{name_domain => shortnames});
        _ -> ok
    end,
    erlang:set_cookie(NodeAtom, binary_to_atom(Cookie, utf8)),
    Interpreted = rpc:call(NodeAtom, int, interpreted, []),
    rpc:call(NodeAtom, init, stop, []),
    Interpreted.
