-module(gleam_dap_value_ffi).
-export([float_to_string/1, read_record_headers/1, gleam_error/1,
         crash_stacktrace/1, crash_reason/1]).

%% Gleam prints floats in their shortest round-trip form, always with a dot.
float_to_string(F) ->
    S = float_to_binary(F, [short]),
    case binary:match(S, [<<".">>, <<"e">>, <<"inf">>, <<"nan">>]) of
        nomatch -> <<S/binary, ".0">>;
        _ -> S
    end.

%% Reads the record headers Gleam generates for custom type constructors
%% with labelled fields: `include/<module>_<Constructor>.hrl`, each holding
%% one `-record(atom, {field, ...})`. Returns [{Atom, Constructor, Fields}].
read_record_headers(IncludeDir) ->
    Files = filelib:wildcard(filename:join(binary_to_list(IncludeDir), "*.hrl")),
    lists:flatmap(fun read_record_header/1, Files).

read_record_header(File) ->
    Base = filename:basename(File, ".hrl"),
    Constructor = case string:split(Base, "_", trailing) of
        [_, C] -> C;
        _ -> Base
    end,
    case epp:parse_file(File, []) of
        {ok, Forms} ->
            [{atom_to_binary(Name, utf8), unicode:characters_to_binary(Constructor),
              [field_name(F) || F <- Fields]}
             || {attribute, _, record, {Name, Fields}} <- Forms];
        _ -> []
    end.

field_name({typed_record_field, Field, _Type}) -> field_name(Field);
field_name({record_field, _, {atom, _, Name}}) -> atom_to_binary(Name, utf8);
field_name({record_field, _, {atom, _, Name}, _}) -> atom_to_binary(Name, utf8).

%% Information about a Gleam error (`panic`, `todo`, `let assert` and
%% friends) in a crash reason: the error map itself, or wrapped with a
%% stack trace as an exit reason.
gleam_error(#{gleam_error := Kind} = Map) ->
    Get = fun(Key, Default) -> maps:get(Key, Map, Default) end,
    {ok, {gleam_error,
          atom_to_binary(Kind, utf8),
          to_text(Get(message, <<>>)),
          to_text(Get(module, <<>>)),
          to_text(Get(function, <<>>)),
          case Get(line, 0) of L when is_integer(L) -> L; _ -> 0 end,
          to_text(Get(file, <<>>))}};
gleam_error({Reason, Stack}) when is_list(Stack) -> gleam_error(Reason);
gleam_error({{Reason, Stack}, _}) when is_list(Stack) -> gleam_error(Reason);
gleam_error(_) -> {error, nil}.

to_text(B) when is_binary(B) -> B;
to_text(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_text(Other) -> gleam_dap_ffi:format_term(Other, 10).

%% The stack trace in an exit reason, as [{Module, Function, Arity, Line}].
crash_stacktrace({_Reason, Stack}) when is_list(Stack) ->
    lists:filtermap(
        fun({M, F, A, Info}) when is_atom(M), is_atom(F) ->
                Arity = case A of N when is_integer(N) -> N; L when is_list(L) -> length(L) end,
                Line = case lists:keyfind(line, 1, Info) of {line, Li} -> Li; false -> 0 end,
                {true, {atom_to_binary(M, utf8), atom_to_binary(F, utf8), Arity, Line}};
           (_) -> false
        end, Stack);
crash_stacktrace(_) -> [].

%% The reason without the stack trace.
crash_reason({Reason, Stack}) when is_list(Stack) -> Reason;
crash_reason(Reason) -> Reason.
