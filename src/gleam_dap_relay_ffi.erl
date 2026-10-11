-module(gleam_dap_relay_ffi).
-export([is_child/0, start/4, forward/2, stop/1]).

%% ---------------------------------------------------------------------------
%% Program arguments.
%%
%% A program reads its command-line arguments with
%% `init:get_plain_arguments()` (the `argv` package does), and they can only
%% be set when a VM starts. So when a launch has `args`, the adapter starts
%% a second adapter VM with those arguments after `-extra`, hands it the
%% `initialize` and `launch` requests, and from then on only relays
%% messages between the editor and it. Debugging then works exactly as
%% without arguments.

%% True in an adapter VM started this way.
is_child() ->
    init:get_argument(gleam_dap_child) =/= error.

%% Starts the child adapter. Messages from it go to the editor; OnExit is
%% called when it exits. Returns the relay process.
start(Args, Initialize, Launch, OnExit) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        process_flag(trap_exit, true),
        Erl = erl_executable(),
        Paths = [P || P <- code:get_path(), P =/= ".",
                      not lists:prefix(code:lib_dir(), P)],
        Port = open_port({spawn_executable, Erl},
                         [{args, ["-noinput", "-gleam_dap_child", "true", "-pa" | Paths]
                                 ++ ["-eval", "gleam_dap:main()", "-extra"
                                     | [unicode:characters_to_list(A) || A <- Args]]},
                          binary, stream, exit_status, hide]),
        send_to(Port, Initialize),
        send_to(Port, Launch),
        Parent ! {self(), started},
        loop(Port, <<>>, false, OnExit)
    end),
    receive {Pid, started} -> Pid end.

erl_executable() ->
    Name = case os:type() of
        {win32, _} -> "erl.exe";
        _ -> "erl"
    end,
    Own = filename:join([code:root_dir(), "bin", Name]),
    case filelib:is_regular(Own) of
        true -> Own;
        false -> os:find_executable("erl")
    end.

forward(Relay, Body) ->
    Relay ! {forward, Body},
    nil.

stop(Relay) ->
    Relay ! stop,
    nil.

send_to(Port, Body) ->
    port_command(Port, 'gleam_dap@dap@framing':encode(Body)).

%% The editor already has the response to `initialize`, from this adapter,
%% so the child's is dropped. Everything else goes through as it is.
loop(Port, Buffer, InitDropped, OnExit) ->
    receive
        {Port, {data, Data}} ->
            {Messages, Rest} = 'gleam_dap@dap@framing':parse(<<Buffer/binary, Data/binary>>),
            Dropped = lists:foldl(fun(Message, Done) ->
                case Done =:= false andalso is_initialize_response(Message) of
                    true -> true;
                    false ->
                        gleam_dap_ffi:write('gleam_dap@dap@framing':encode(Message)),
                        Done
                end
            end, InitDropped, Messages),
            loop(Port, Rest, Dropped, OnExit);
        {forward, Body} ->
            send_to(Port, Body),
            loop(Port, Buffer, InitDropped, OnExit);
        stop ->
            catch port_close(Port),
            OnExit(0);
        {Port, {exit_status, Status}} ->
            OnExit(Status);
        {'EXIT', Port, _} ->
            OnExit(1)
    end.

is_initialize_response(Message) ->
    try json:decode(Message) of
        #{<<"type">> := <<"response">>, <<"command">> := <<"initialize">>} -> true;
        _ -> false
    catch _:_ -> false
    end.
