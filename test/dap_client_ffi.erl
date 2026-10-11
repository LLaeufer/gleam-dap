%% A small DAP client for the integration tests. It starts the adapter in
%% its own VM, the way an editor would, and talks to it over stdio.
-module(dap_client_ffi).
-export([start/0, request/3, wait_event/3, stop/1, project_root/0]).

-define(TIMEOUT, 30000).

project_root() ->
    {ok, Cwd} = file:get_cwd(),
    unicode:characters_to_binary(Cwd).

start() ->
    Self = self(),
    Pid = spawn_link(fun() -> init(Self) end),
    receive {Pid, started} -> Pid end.

init(Owner) ->
    {ok, Cwd} = file:get_cwd(),
    Ebins = filelib:wildcard(filename:join(Cwd, "build/dev/erlang/*/ebin")),
    Log = filename:join(Cwd, "build/gleam-dap-test.log"),
    %% GLEAM_DAP_COMMAND runs the tests against a packaged adapter instead.
    {Exe, Args} = case os:getenv("GLEAM_DAP_COMMAND") of
        false ->
            {os:find_executable("erl"),
             ["-noinput", "-pa" | Ebins] ++ ["-eval", "gleam_dap:main()"]};
        Command ->
            %% Windows runs a .cmd launcher through cmd.exe.
            case filename:extension(Command) of
                ".cmd" -> {os:find_executable("cmd"), ["/c", Command]};
                _ -> {Command, []}
            end
    end,
    Port = open_port({spawn_executable, Exe},
                     [{args, Args},
                      {env, [{"GLEAM_DAP_LOG", Log}]},
                      binary, stream, exit_status]),
    Owner ! {self(), started},
    loop(#{port => Port, buffer => <<>>, seq => 0, waiting => #{},
           events => [], event_waiters => []}).

loop(#{port := Port} = S) ->
    receive
        {Port, {data, Data}} ->
            {Messages, Rest} = 'gleam_dap@dap@framing':parse(
                                 <<(maps:get(buffer, S))/binary, Data/binary>>),
            S1 = lists:foldl(fun handle_message/2, S#{buffer => Rest},
                             [json:decode(M) || M <- Messages]),
            loop(check_event_waiters(S1));
        {Port, {exit_status, _}} ->
            loop(S#{port => closed});
        {request, From, Command, Args} ->
            Seq = maps:get(seq, S) + 1,
            Body = iolist_to_binary(json:encode(#{<<"seq">> => Seq,
                                                  <<"type">> => <<"request">>,
                                                  <<"command">> => Command,
                                                  <<"arguments">> => json:decode(Args)})),
            port_command(Port, ["Content-Length: ", integer_to_list(byte_size(Body)),
                                "\r\n\r\n", Body]),
            loop(S#{seq => Seq, waiting => (maps:get(waiting, S))#{Seq => From}});
        {wait_event, From, Name} ->
            loop(check_event_waiters(
                   S#{event_waiters => maps:get(event_waiters, S) ++ [{From, Name}]}));
        stop ->
            catch port_close(Port),
            ok
    end.

handle_message(#{<<"type">> := <<"response">>, <<"request_seq">> := Seq} = M, S) ->
    Waiting = maps:get(waiting, S),
    case maps:take(Seq, Waiting) of
        {From, Rest} -> From ! {dap_response, M}, S#{waiting => Rest};
        error -> S
    end;
handle_message(#{<<"type">> := <<"event">>} = M, S) ->
    S#{events => maps:get(events, S) ++ [M]};
handle_message(_, S) ->
    S.

%% A waiter takes the first matching event and drops the events before it,
%% so consecutive waits read the event stream in order.
check_event_waiters(#{event_waiters := []} = S) -> S;
check_event_waiters(#{event_waiters := [{From, Name} | Rest], events := Events} = S) ->
    case lists:splitwith(fun(E) -> maps:get(<<"event">>, E) =/= Name end, Events) of
        {_, [Event | After]} ->
            From ! {dap_event, Event},
            check_event_waiters(S#{event_waiters => Rest, events => After});
        {_, []} -> S
    end.

request(Client, Command, Args) ->
    Client ! {request, self(), Command, Args},
    receive {dap_response, M} -> {ok, M}
    after ?TIMEOUT -> {error, <<"timeout waiting for response to ", Command/binary>>}
    end.

wait_event(Client, Name, Timeout) ->
    Client ! {wait_event, self(), Name},
    receive {dap_event, M} -> {ok, M}
    after Timeout -> {error, <<"timeout waiting for event ", Name/binary>>}
    end.

stop(Client) ->
    Client ! stop,
    nil.
