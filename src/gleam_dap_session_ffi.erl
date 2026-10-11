-module(gleam_dap_session_ffi).
-export([or_none/1, spawn_worker/1, detach_all/0, stop_node/1, is_shutdown/1,
         is_normal/1, register/2]).

%% Option(String) to a binary or the atom `none`, for the Erlang side.
or_none({some, V}) -> V;
or_none(none) -> none.

spawn_worker(Fun) ->
    spawn(Fun).

%% Removes every breakpoint and stops interpreting, so an attached node is
%% left as it was.
detach_all() ->
    catch int:auto_attach(false),
    catch int:no_break(),
    catch gleam_dap_eval_ffi:unload_remote(),
    catch int:nn(int:interpreted()),
    nil.

%% Stops an attached node, for "terminate" in an attach session.
stop_node(<<>>) -> nil;
stop_node(Node) ->
    catch rpc:call(binary_to_atom(Node, utf8), init, stop, [], 2000),
    nil.

is_shutdown(shutdown) -> true;
is_shutdown({shutdown, _}) -> true;
is_shutdown(killed) -> true;
is_shutdown(normal) -> true;
is_shutdown(_) -> false.

is_normal(normal) -> true;
is_normal(_) -> false.

register(Pid, Name) ->
    try erlang:register(binary_to_atom(Name, utf8), Pid)
    catch _:_ -> false
    end.
