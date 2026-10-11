#!/usr/bin/env escript
%% Builds a self-contained copy of the adapter in dist/gleam-dap:
%%
%%   dist/gleam-dap/bin/gleam-dap     launcher the editor runs
%%   dist/gleam-dap/bin/gleam-dap.cmd the same, for Windows
%%   dist/gleam-dap/ebin/*.beam       the adapter and its dependencies
%%
%% Dependencies (gleam_stdlib, gleam_erlang) are renamed with a
%% `gleam_dap@vendor@` prefix. The program being debugged runs in the same
%% VM and usually depends on its own copies of these packages, maybe in
%% other versions. Renaming keeps the two apart, and lets users interpret
%% their own copy of, say, `gleam/list` without the adapter ever running
%% interpreted code itself.
%%
%% Usage: scripts/package.escript [OutputDir]
-mode(compile).

-define(PREFIX, "gleam_dap@vendor@").
-define(OWN, "gleam_dap").

main(Args) ->
    Out = case Args of [Dir] -> Dir; [] -> "dist/gleam-dap" end,
    {0, Output} = run("gleam export erlang-shipment"),
    io:format("~s", [Output]),
    Shipment = "build/erlang-shipment",
    Packages = [filename:basename(filename:dirname(E))
                || E <- filelib:wildcard(filename:join(Shipment, "*/ebin"))],
    Deps = Packages -- [?OWN, "gleeunit"],
    Renames = maps:from_list(
        [{M, list_to_atom(?PREFIX ++ atom_to_list(M))}
         || P <- Deps, M <- modules(Shipment, P)]),
    Skip = test_modules(),
    Ebin = filename:join(Out, "ebin"),
    ok = del_dir(Out),
    ok = filelib:ensure_path(Ebin),
    lists:foreach(
        fun(P) ->
            lists:foreach(
                fun(Beam) ->
                    Mod = list_to_atom(filename:basename(Beam, ".beam")),
                    case lists:member(Mod, Skip) of
                        true -> ok;
                        false -> rewrite(Beam, Renames, Ebin)
                    end
                end,
                filelib:wildcard(filename:join([Shipment, P, "ebin", "*.beam"])))
        end, Packages -- ["gleeunit"]),
    write_launchers(Out),
    io:format("Packaged the adapter in ~s (~p modules renamed)~n",
              [Out, maps:size(Renames)]).

%% Test code ends up in the shipment too; leave it out.
test_modules() ->
    Own = [list_to_atom(filename:basename(F, ".erl")) || F <- filelib:wildcard("test/**/*.erl")]
        ++ [list_to_atom(lists:flatten(string:replace(filename:rootname(F), "/", "@", all)))
            || F <- filelib:wildcard("**/*.gleam", "test")],
    Deps = [M || F <- filelib:wildcard("build/erlang-shipment/*/ebin/*_test_ffi.beam"),
                 M <- [list_to_atom(filename:basename(F, ".beam"))]],
    Gleeunit = [M || F <- filelib:wildcard("build/erlang-shipment/*/ebin/gleeunit*.beam"),
                     M <- [list_to_atom(filename:basename(F, ".beam"))]],
    Own ++ Deps ++ Gleeunit.

modules(Shipment, Package) ->
    [list_to_atom(filename:basename(B, ".beam"))
     || B <- filelib:wildcard(filename:join([Shipment, Package, "ebin", "*.beam"]))].

rewrite(Beam, Renames, Ebin) ->
    {ok, {Mod, [{debug_info, {debug_info_v1, Backend, Data}}]}} =
        beam_lib:chunks(Beam, [debug_info]),
    {ok, Forms} = Backend:debug_info(erlang_v1, Mod, Data, []),
    Renamed = rename(Forms, Renames),
    NewMod = maps:get(Mod, Renames, Mod),
    case compile:forms(Renamed, [binary, return_errors, no_spawn_compiler_process]) of
        {ok, NewMod, Bin} ->
            ok = file:write_file(filename:join(Ebin, atom_to_list(NewMod) ++ ".beam"), Bin);
        {ok, NewMod, Bin, _Warnings} ->
            ok = file:write_file(filename:join(Ebin, atom_to_list(NewMod) ++ ".beam"), Bin);
        Error ->
            io:format("could not recompile ~p: ~p~n", [Mod, Error]),
            halt(1)
    end.

rename({atom, A, Name}, Renames) when is_map_key(Name, Renames) ->
    {atom, A, maps:get(Name, Renames)};
rename({attribute, A, module, M}, Renames) ->
    {attribute, A, module, maps:get(M, Renames, M)};
rename({'fun', A, {function, M, F, Arity}}, Renames) when is_atom(M) ->
    {'fun', A, {function, maps:get(M, Renames, M), F, Arity}};
rename(T, Renames) when is_tuple(T) ->
    list_to_tuple(rename(tuple_to_list(T), Renames));
rename([H | T], Renames) ->
    [rename(H, Renames) | rename(T, Renames)];
rename(Other, _) ->
    Other.

write_launchers(Out) ->
    Bin = filename:join(Out, "bin"),
    ok = filelib:ensure_path(Bin),
    Sh = filename:join(Bin, "gleam-dap"),
    ok = file:write_file(Sh,
        "#!/bin/sh\n"
        "# Starts the gleam-dap debug adapter. It speaks DAP on stdin/stdout.\n"
        "# Needs Erlang/OTP 27 or newer with the debugger application.\n"
        "DIR=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"\n"
        "exec erl -noinput -pa \"$DIR/ebin\" -eval 'gleam_dap:main()' -extra \"$@\"\n"),
    ok = file:change_mode(Sh, 8#755),
    Cmd = filename:join(Bin, "gleam-dap.cmd"),
    ok = file:write_file(Cmd,
        "@echo off\r\n"
        "rem Starts the gleam-dap debug adapter on Windows. It speaks DAP on\r\n"
        "rem stdin/stdout. Needs Erlang/OTP 27 or newer with the debugger application.\r\n"
        "erl.exe -noinput -pa \"%~dp0..\\ebin\" -eval \"gleam_dap:main()\" -extra %*\r\n").

del_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true -> file:del_dir_r(Dir);
        false -> ok
    end.

run(Cmd) ->
    Port = open_port({spawn, Cmd}, [exit_status, stderr_to_stdout, binary]),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, [Acc, D]);
        {Port, {exit_status, S}} -> {S, iolist_to_binary(Acc)}
    end.
