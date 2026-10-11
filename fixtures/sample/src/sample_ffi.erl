-module(sample_ffi).
-export([println/1, spawn/1, sleep/1, self_name/0, arguments/0]).

println(String) ->
    io:put_chars([String, $\n]),
    nil.

spawn(Fun) ->
    erlang:spawn(Fun).

sleep(Ms) ->
    timer:sleep(Ms),
    nil.

self_name() ->
    list_to_binary(pid_to_list(self())).

%% The command-line arguments, joined with `|`, as `argv` would read them.
arguments() ->
    unicode:characters_to_binary(lists:join("|", init:get_plain_arguments())).
