%% Evaluating expressions in the debug console, watches, hovers, breakpoint
%% conditions and logpoints.
%%
%% Expressions are Erlang expressions with a thin Gleam layer on top:
%% Gleam variable names (`x` for the latest `X@N`), `True`/`False`/`Nil`,
%% Gleam strings, `!=`, `&&`, `||`, field access (`person.name`,
%% `pair.0`) and module calls (`list.length(xs)`).
-module(gleam_dap_eval_ffi).

-export([
    eval/2, set_labels/1, field/2,
    set_conditions/2, check/2, interpolate/2
]).

-define(EVAL_TIMEOUT, 5000).

%% ---------------------------------------------------------------------------
%% Evaluate

%% Bindings is [{ErlangName :: binary(), Value}].
eval(Source, Bindings) ->
    case gleam_dap_ffi:run_with_timeout(fun() -> eval_now(Source, Bindings) end,
                                        ?EVAL_TIMEOUT) of
        {ok, Result} -> Result;
        {error, Reason} -> {error, Reason}
    end.

eval_now(Source, Bindings) ->
    try
        Tokens = tokens(Source, Bindings),
        {ok, Exprs} = case erl_parse:parse_exprs(Tokens) of
            {ok, _} = Ok -> Ok;
            {error, {_, Mod, Desc}} -> throw({syntax, Mod:format_error(Desc)})
        end,
        Bs = lists:foldl(fun({K, V}, Acc) ->
                             erl_eval:add_binding(binary_to_atom(K, utf8), V, Acc)
                         end, erl_eval:new_bindings(), Bindings),
        {value, Value, _} = erl_eval:exprs(Exprs, Bs, {value, fun local/2}),
        {ok, Value}
    catch
        throw:{unknown_variable, Name} ->
            {error, unicode:characters_to_binary(
                       io_lib:format("Unknown variable ~ts", [Name]))};
        throw:{syntax, Message} ->
            {error, unicode:characters_to_binary(["Syntax error: ", Message])};
        error:{unbound_var, Var} ->
            {error, unicode:characters_to_binary(
                       io_lib:format("Unknown variable ~ts", [gleam_name(Var)]))};
        Class:Reason ->
            {error, gleam_dap_ffi:format_term({Class, Reason}, 8)}
    end.

local(Name, Args) ->
    erlang:error({undefined_function, Name, length(Args)}).

gleam_name(Var) ->
    case atom_to_list(Var) of
        [C | Rest] when C >= $A, C =< $Z -> [C + 32 | Rest];
        Other -> Other
    end.

tokens(Source, Bindings) ->
    Text = rewrite_operators(unicode:characters_to_list(Source)),
    case erl_scan:string(Text) of
        {ok, Tokens, End} ->
            Names = gleam_names(Bindings),
            Rewritten = rewrite(Tokens, Names),
            Rewritten ++ [{dot, End}];
        {error, {_, Mod, Desc}, _} ->
            throw({syntax, Mod:format_error(Desc)})
    end.

rewrite_operators("!=" ++ Rest) -> "/=" ++ rewrite_operators(Rest);
rewrite_operators("&&" ++ Rest) -> " andalso " ++ rewrite_operators(Rest);
rewrite_operators("||" ++ Rest) -> " orelse " ++ rewrite_operators(Rest);
rewrite_operators([$" | Rest]) ->
    {String, After} = string_literal(Rest, []),
    [$" | String] ++ rewrite_operators(After);
rewrite_operators([C | Rest]) -> [C | rewrite_operators(Rest)];
rewrite_operators([]) -> [].

string_literal([$\\, C | Rest], Acc) -> string_literal(Rest, [C, $\\ | Acc]);
string_literal([$" | Rest], Acc) -> {lists:reverse([$" | Acc]), Rest};
string_literal([C | Rest], Acc) -> string_literal(Rest, [C | Acc]);
string_literal([], Acc) -> {lists:reverse(Acc), []}.

%% Gleam name (atom) => Erlang name (atom) of the latest version.
gleam_names(Bindings) ->
    lists:foldl(
        fun({Name, _}, Acc) ->
            case demangle(Name) of
                {ok, Gleam, Version} ->
                    case maps:get(Gleam, Acc, undefined) of
                        {_, V} when V >= Version -> Acc;
                        _ -> Acc#{Gleam => {binary_to_atom(Name, utf8), Version}}
                    end;
                error -> Acc
            end
        end, #{}, Bindings).

demangle(<<"_", _/binary>>) -> error;
demangle(<<First, Rest/binary>> = Name) when First >= $A, First =< $Z ->
    {Base, Version} = case binary:split(Rest, <<"@">>) of
        [B, V] ->
            try {B, binary_to_integer(V)} catch _:_ -> {Rest, 0} end;
        [B] -> {B, 0}
    end,
    _ = Name,
    {ok, binary_to_atom(<<(First + 32), Base/binary>>, utf8), Version};
demangle(_) -> error.

rewrite([{var, L, 'True'} | Rest], Names) -> [{atom, L, true} | rewrite(Rest, Names)];
rewrite([{var, L, 'False'} | Rest], Names) -> [{atom, L, false} | rewrite(Rest, Names)];
rewrite([{var, L, 'Nil'} | Rest], Names) -> [{atom, L, nil} | rewrite(Rest, Names)];
rewrite([{string, L, S} | Rest], Names) ->
    [{'<<', L}, {string, L, S}, {'/', L}, {atom, L, utf8}, {'>>', L}
     | rewrite(Rest, Names)];
%% module.function( → gleam@module:function(
rewrite([{atom, L, M}, {'.', _}, {atom, _, F}, {'(', _} = Open | Rest], Names)
  when not is_map_key(M, Names) ->
    [{atom, L, resolve_module(M)}, {':', L}, {atom, L, F}, Open | rewrite(Rest, Names)];
rewrite([{atom, L, Name} | Rest], Names) when is_map_key(Name, Names) ->
    {Var, _} = maps:get(Name, Names),
    access({var, L, Var}, Rest, Names);
%% Erlang-style calls (`erlang:length(x)`, `f(x)`) keep their atoms.
rewrite([{atom, _, _} = A, {':', _} = C | Rest], Names) -> [A, C | rewrite(Rest, Names)];
rewrite([{atom, _, _} = A, {'(', _} = O | Rest], Names) -> [A, O | rewrite(Rest, Names)];
%% Any other lowercase name is a Gleam variable that isn't bound.
rewrite([{atom, _, Name} | _], _Names) ->
    throw({unknown_variable, Name});
rewrite([{var, _, _} = Var | Rest], Names) ->
    access(Var, Rest, Names);
rewrite([T | Rest], Names) -> [T | rewrite(Rest, Names)];
rewrite([], _) -> [].

%% Field access after a variable: `x.name`, `x.0`, chained.
access(Expr, [{'.', L}, {atom, _, Field} | Rest], Names) ->
    access_call(Expr, {atom, L, Field}, L, Rest, Names);
access(Expr, [{'.', L}, {integer, _, N} | Rest], Names) ->
    access_call(Expr, {integer, L, N}, L, Rest, Names);
access(Expr, Rest, Names) when is_tuple(Expr) ->
    [Expr | rewrite(Rest, Names)];
access(Exprs, Rest, Names) when is_list(Exprs) ->
    Exprs ++ rewrite(Rest, Names).

access_call(Expr, Key, L, Rest, Names) ->
    Inner = case Expr of
        T when is_tuple(T) -> [T];
        Ts -> Ts
    end,
    Call = [{atom, L, ?MODULE}, {':', L}, {atom, L, field}, {'(', L}]
           ++ Inner ++ [{',', L}, Key, {')', L}],
    access(Call, Rest, Names).

resolve_module(M) ->
    case code:is_loaded(M) of
        {file, _} -> M;
        false ->
            Suffix = "@" ++ atom_to_list(M),
            Gleam = list_to_atom("gleam" ++ Suffix),
            case code:is_loaded(Gleam) of
                {file, _} -> Gleam;
                false ->
                    Matches = [Mod || {Mod, _} <- code:all_loaded(),
                                      lists:suffix(Suffix, atom_to_list(Mod))],
                    case Matches of
                        [Found | _] -> Found;
                        [] -> M
                    end
            end
    end.

%% ---------------------------------------------------------------------------
%% Field access on custom types, using labels from the record headers.

%% Labels is [{{Tag, Arity}, {Constructor, Fields}}].
set_labels(Labels) ->
    Map = maps:from_list(Labels),
    persistent_term:put(gleam_dap_labels, Map),
    nil.

field(Tuple, N) when is_tuple(Tuple), is_integer(N) ->
    element(N + 1, Tuple);
field(Record, Label) when is_tuple(Record), tuple_size(Record) > 1,
                          is_atom(element(1, Record)), is_atom(Label) ->
    Tag = atom_to_binary(element(1, Record), utf8),
    Labels = persistent_term:get(gleam_dap_labels, #{}),
    Key = {Tag, tuple_size(Record) - 1},
    LabelBin = atom_to_binary(Label, utf8),
    case maps:get(Key, Labels, undefined) of
        undefined -> erlang:error({unknown_field, Label});
        {_Constructor, Fields} ->
            case index_of(LabelBin, Fields, 1) of
                0 -> erlang:error({unknown_field, Label});
                I -> element(I + 1, Record)
            end
    end;
field(Map, Key) when is_map(Map) ->
    maps:get(Key, Map);
field(_, Label) ->
    erlang:error({unknown_field, Label}).

index_of(_, [], _) -> 0;
index_of(X, [X | _], I) -> I;
index_of(X, [_ | T], I) -> index_of(X, T, I + 1).

%% ---------------------------------------------------------------------------
%% Breakpoint conditions, hit counts and logpoints
%%
%% `int:test_at_break/3` calls a function with only the bindings, so each
%% conditional breakpoint needs its own function. We generate a module with
%% one `check_N/1` per slot, each calling `check(N, Bindings)`.

%% Conditions is [{Slot, Condition, HitCondition, LogMessage}] where each
%% field is a binary or `none`. OnLog is called with the logpoint output and
%% OnError with error messages.
set_conditions(Conditions, {OnLog, OnError}) ->
    case ets:info(gleam_dap_conditions) of
        undefined ->
            ets:new(gleam_dap_conditions, [named_table, public, set]);
        _ ->
            ets:delete_all_objects(gleam_dap_conditions)
    end,
    persistent_term:put(gleam_dap_condition_callbacks, {OnLog, OnError}),
    lists:foreach(
        fun({Slot, Condition, Hit, Log}) ->
            ets:insert(gleam_dap_conditions, {Slot, Condition, Hit, Log, 0})
        end, Conditions),
    Slots = lists:max([0 | [S || {S, _, _, _} <- Conditions]]),
    ensure_module(Slots),
    nil.

ensure_module(Slots) ->
    Current = persistent_term:get(gleam_dap_condition_slots, 0),
    case Slots =< Current of
        true -> ok;
        false ->
            Size = ((Slots div 32) + 1) * 32,
            Mod = gleam_dap_conditions,
            Forms = [{attribute, 1, module, Mod},
                     {attribute, 1, export, [{check_name(N), 1} || N <- lists:seq(1, Size)]}
                     | [check_form(N) || N <- lists:seq(1, Size)]],
            {ok, Mod, Bin} = compile:forms(Forms, [binary]),
            code:purge(Mod),
            {module, Mod} = code:load_binary(Mod, "gleam_dap_conditions.erl", Bin),
            persistent_term:put(gleam_dap_condition_slots, Size)
    end.

check_name(N) -> list_to_atom("check_" ++ integer_to_list(N)).

check_form(N) ->
    {function, 1, check_name(N), 1,
     [{clause, 1, [{var, 1, 'Bs'}], [],
       [{call, 1, {remote, 1, {atom, 1, ?MODULE}, {atom, 1, check}},
         [{integer, 1, N}, {var, 1, 'Bs'}]}]}]}.

%% Runs inside the interpreter, so it must be quick and must never call into
%% interpreted code.
check(Slot, Bs) ->
    case ets:lookup(gleam_dap_conditions, Slot) of
        [{Slot, Condition, Hit, Log, _}] ->
            Bindings = [{atom_to_binary(K, utf8), V} || {K, V} <- erl_eval:bindings(Bs)],
            case condition_holds(Condition, Bindings) of
                false -> false;
                true ->
                    Hits = ets:update_counter(gleam_dap_conditions, Slot, {5, 1}),
                    case hit_holds(Hit, Hits) of
                        false -> false;
                        true ->
                            case Log of
                                none -> true;
                                Message ->
                                    {OnLog, _} = callbacks(),
                                    OnLog(interpolate(Message, Bindings)),
                                    false
                            end
                    end
            end;
        [] -> true
    end.

callbacks() ->
    persistent_term:get(gleam_dap_condition_callbacks,
                        {fun(_) -> nil end, fun(_) -> nil end}).

condition_holds(none, _) -> true;
condition_holds(Condition, Bindings) ->
    case eval_now(Condition, Bindings) of
        {ok, true} -> true;
        {ok, _} -> false;
        {error, Message} ->
            {_, OnError} = callbacks(),
            OnError(<<"Breakpoint condition `", Condition/binary, "` failed: ",
                      Message/binary>>),
            false
    end.

hit_holds(none, _) -> true;
hit_holds(Hit, Hits) ->
    Text = string:trim(binary_to_list(Hit)),
    {Op, Number} = case Text of
        ">=" ++ N -> {'>=', N};
        "<=" ++ N -> {'=<', N};
        "==" ++ N -> {'==', N};
        ">" ++ N -> {'>', N};
        "<" ++ N -> {'<', N};
        "%" ++ N -> {'rem', N};
        N -> {'>=', N}
    end,
    case string:to_integer(string:trim(Number)) of
        {Int, _} when is_integer(Int) ->
            case Op of
                'rem' -> Int > 0 andalso Hits rem Int =:= 0;
                _ -> erlang:Op(Hits, Int)
            end;
        _ -> true
    end.

%% Replaces `{expression}` in a logpoint message with its value.
interpolate(Message, Bindings) ->
    iolist_to_binary(interpolate_parts(Message, Bindings)).

interpolate_parts(<<"{", Rest/binary>>, Bindings) ->
    case binary:split(Rest, <<"}">>) of
        [Expr, After] ->
            Value = case eval_now(Expr, Bindings) of
                {ok, V} -> render(V);
                {error, E} -> [<<"<error: ">>, E, <<">">>]
            end,
            [Value | interpolate_parts(After, Bindings)];
        [_] -> [<<"{">>, Rest]
    end;
interpolate_parts(<<C/utf8, Rest/binary>>, Bindings) ->
    [<<C/utf8>> | interpolate_parts(Rest, Bindings)];
interpolate_parts(<<>>, _) -> [].

render(Value) ->
    Labels = persistent_term:get(gleam_dap_labels, #{}),
    'gleam_dap@value':render_with_labels(Value, maps:to_list(Labels)).
