#!/usr/bin/env escript
%% Step 1 feasibility spike: build a Gleam project, interpret its modules
%% with `int`, stop on a breakpoint and step through, printing the Gleam
%% line, the bindings and the backtrace at every stop.
%%
%% Usage: scripts/spike.escript [ProjectDir] [Module] [Line] [Steps] [Entry]
%% Defaults: fixtures/sample sample 8 40 main
-mode(compile).
-export([on_break/2]).

main(Args) ->
    [Dir, Mod, Line, Steps, Entry] = defaults(Args),
    io:format("OTP ~s~n", [erlang:system_info(otp_release)]),
    {0, Out} = run("gleam build --target erlang", Dir),
    io:format("~s", [Out]),
    Pkg = package_name(Dir),
    Ebins = filelib:wildcard(filename:join(Dir, "build/dev/erlang/*/ebin")),
    ok = code:add_pathsa(Ebins),
    Ebin = filename:join([Dir, "build/dev/erlang", Pkg, "ebin"]),
    {ok, _} = application:ensure_all_started(debugger),
    Mods = interpret_all(Dir, Ebin),
    io:format("interpreted: ~p~n", [Mods]),
    ok = int:break(list_to_atom(Mod), list_to_integer(Line)),
    Self = self(),
    int:auto_attach([break], {?MODULE, on_break, [Self]}),
    int:stack_trace(all),
    Pid = spawn(list_to_atom(Pkg), list_to_atom(Entry), []),
    loop(Pid, list_to_integer(Steps)).

defaults(Args) ->
    Ds = ["fixtures/sample", "sample", "8", "40", "main"],
    Args ++ lists:nthtail(length(Args), Ds).

on_break(Pid, Listener) ->
    Listener ! {break, Pid}.

loop(_Pid, 0) ->
    io:format("step limit reached~n"),
    halt(0);
loop(Pid, N) ->
    receive
        {break, P} ->
            report(P),
            int:step(P),
            loop(Pid, N - 1)
    after 3000 ->
        io:format("no more stops~n"),
        halt(0)
    end.

report(Pid) ->
    {ok, Meta} = dbg_iserver:safe_call({get_meta, Pid}),
    {_, _, break, {M, L}} = lists:keyfind(Pid, 1, int:snapshot()),
    Bs = int:meta(Meta, bindings, nostack),
    Bt = int:meta(Meta, backtrace, all),
    io:format("~p ~s:~p~n  bindings: ~0tP~n  backtrace: ~0tP~n",
              [Pid, M, L, Bs, 12, [fn_name(MFA) || {_, MFA} <- Bt], 20]).

fn_name({M, F, As}) when is_list(As) -> {M, F, length(As)};
fn_name({Fun, As}) when is_function(Fun) -> {Fun, length(As)};
fn_name(Other) -> Other.

interpret_all(Dir, Ebin) ->
    Beams = filelib:wildcard(filename:join(Ebin, "*.beam")),
    lists:filtermap(
      fun(Beam) ->
              {ok, Bin} = file:read_file(Beam),
              case beam_lib:chunks(Bin, [abstract_code]) of
                  {ok, {Mod, [{abstract_code, {_, Forms}}]}} ->
                      case [F || {attribute, _, file, {F, _}} <- Forms] of
                          [Src | _] ->
                              case lists:suffix(".gleam", Src) of
                                  true ->
                                      Abs = filename:join(Dir, Src),
                                      {module, Mod} = int:i({Mod, Abs, Beam, Bin}),
                                      {true, Mod};
                                  false -> false
                              end;
                          [] -> false
                      end;
                  _ -> false
              end
      end, Beams).

package_name(Dir) ->
    {ok, Toml} = file:read_file(filename:join(Dir, "gleam.toml")),
    {match, [Name]} = re:run(Toml, "^name\\s*=\\s*\"([^\"]+)\"",
                             [multiline, {capture, all_but_first, list}]),
    Name.

run(Cmd, Dir) ->
    Port = open_port({spawn, Cmd}, [{cd, Dir}, exit_status, stderr_to_stdout, binary]),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, [Acc, D]);
        {Port, {exit_status, S}} -> {S, iolist_to_binary(Acc)}
    end.
