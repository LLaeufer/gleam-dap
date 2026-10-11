%% Gleam expressions for the debug console, watches, hovers, breakpoint
%% conditions and logpoints.
%%
%% There is no Gleam compiler in the VM, so this is a small Gleam front end:
%% it reads a Gleam expression (or a few statements) and translates it into
%% Erlang abstract syntax, which `erl_eval` runs with the bindings of the
%% stopped frame. It covers the expression language: literals, strings with
%% escapes, lists, tuples, bit arrays, records with labels, record updates,
%% all operators with Gleam's precedence and semantics, pipes (with `_`
%% captures), field access, module calls, anonymous functions, blocks,
%% `let`, `let assert` and `case` with guards. Types are not checked: a
%% wrong expression fails when it runs instead.
-module(gleam_dap_gleam_eval).

-export([compile/3]).

%% Names is #{GleamName :: atom() => {ErlangName :: atom(), Version}}, the
%% latest binding of each Gleam variable. Module is the module of the
%% frame (a binary), for calls without a module, or `undefined`.
%%
%% Returns {ok, Forms} or {error, Message}.
compile(Source, Names, Module) ->
    try
        Tokens = lex(unicode:characters_to_list(Source)),
        {Statements, []} = statements(Tokens, eof),
        Env = #{names => Names, vars => #{}, module => Module},
        {ok, compile_statements(Statements, Env)}
    catch
        throw:{gleam_error, Message} ->
            {error, unicode:characters_to_binary(Message)};
        throw:{unknown_variable, Name} ->
            {error, unicode:characters_to_binary(io_lib:format("Unknown variable ~ts", [Name]))}
    end.

fail(Format, Args) ->
    throw({gleam_error, lists:flatten(io_lib:format(Format, Args))}).

%% ---------------------------------------------------------------------------
%% Lexer. Tokens are {Kind, Column} or {Kind, Column, Value}.

lex(Text) -> lex(Text, 1, none, []).

lex([], _, _, Acc) -> lists:reverse(Acc);
lex([C | Rest], Col, Prev, Acc) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    lex(Rest, Col + 1, Prev, Acc);
lex("//" ++ Rest, Col, Prev, Acc) ->
    {_, After} = lists:splitwith(fun(C) -> C =/= $\n end, Rest),
    lex(After, Col + 2 + length(Rest) - length(After), Prev, Acc);
lex([$" | Rest], Col, _, Acc) ->
    {Chars, After} = string_chars(Rest, Col, []),
    Token = {string, Col, Chars},
    lex(After, Col + 2 + length(Rest) - length(After), Token, [Token | Acc]);
lex([C | _] = Text, Col, Prev, Acc) when C >= $0, C =< $9 ->
    %% After a `.`, only an integer: `pair.0.1` is two indexes.
    AfterDot = case Prev of {'.', _} -> true; _ -> false end,
    {Token, After} = number(Text, Col, AfterDot),
    lex(After, Col + length(Text) - length(After), Token, [Token | Acc]);
lex([C | _] = Text, Col, _, Acc) when (C >= $a andalso C =< $z); C =:= $_ ->
    {Word, After} = lists:splitwith(fun is_name_char/1, Text),
    Token = case Word of
        "fn" -> {fn, Col};
        "let" -> {'let', Col};
        "case" -> {'case', Col};
        "if" -> {'if', Col};
        "as" -> {as, Col};
        "assert" -> {assert, Col};
        "todo" -> {todo, Col};
        "panic" -> {panic, Col};
        "use" -> fail("`use` isn't supported in the debug console", []);
        "_" ++ _ -> {discard, Col, Word};
        _ -> {name, Col, Word}
    end,
    lex(After, Col + length(Word), Token, [Token | Acc]);
lex([C | _] = Text, Col, _, Acc) when C >= $A, C =< $Z ->
    {Word, After} = lists:splitwith(fun is_name_char/1, Text),
    Token = {upname, Col, Word},
    lex(After, Col + length(Word), Token, [Token | Acc]);
lex(Text, Col, _, Acc) ->
    case symbol(Text) of
        {Symbol, After} ->
            Token = {Symbol, Col},
            lex(After, Col + length(Text) - length(After), Token, [Token | Acc]);
        error ->
            fail("Unexpected character `~ts` at column ~b", [[hd(Text)], Col])
    end.

is_name_char(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
        orelse (C >= $0 andalso C =< $9) orelse C =:= $_.

%% Longest symbols first.
-define(SYMBOLS, [
    "<=.", ">=.", "..", "<<", ">>", "|>", "||", "&&", "==", "!=", "<=", ">=",
    "<.", ">.", "<>", "->", "+.", "-.", "*.", "/.",
    "(", ")", "[", "]", "{", "}", ",", ".", ":", "#", "=", "<", ">", "+", "-",
    "*", "/", "%", "!", "|"
]).

symbol(Text) -> symbol(Text, ?SYMBOLS).

symbol(_, []) -> error;
symbol(Text, [S | Rest]) ->
    case lists:prefix(S, Text) of
        true -> {list_to_atom(S), lists:nthtail(length(S), Text)};
        false -> symbol(Text, Rest)
    end.

string_chars([$\\, C | Rest], Col, Acc) ->
    case C of
        $n -> string_chars(Rest, Col, [$\n | Acc]);
        $r -> string_chars(Rest, Col, [$\r | Acc]);
        $t -> string_chars(Rest, Col, [$\t | Acc]);
        $f -> string_chars(Rest, Col, [$\f | Acc]);
        $e -> string_chars(Rest, Col, [27 | Acc]);
        $" -> string_chars(Rest, Col, [$" | Acc]);
        $\\ -> string_chars(Rest, Col, [$\\ | Acc]);
        $u ->
            case Rest of
                [${ | More] ->
                    {Hex, [$} | After]} = lists:splitwith(fun(X) -> X =/= $} end, More),
                    string_chars(After, Col, [list_to_integer(Hex, 16) | Acc]);
                _ -> fail("Invalid \\u escape in the string at column ~b", [Col])
            end;
        _ -> fail("Unknown escape \\~ts in the string at column ~b", [[C], Col])
    end;
string_chars([$" | Rest], _, Acc) -> {lists:reverse(Acc), Rest};
string_chars([C | Rest], Col, Acc) -> string_chars(Rest, Col, [C | Acc]);
string_chars([], Col, _) -> fail("Unterminated string at column ~b", [Col]).

number("0x" ++ Rest, Col, _) -> based(Rest, 16, Col);
number("0o" ++ Rest, Col, _) -> based(Rest, 8, Col);
number("0b" ++ Rest, Col, _) -> based(Rest, 2, Col);
number(Text, Col, AfterDot) ->
    {Int, After} = digits(Text),
    case After of
        [$., D | _] when not AfterDot, D >= $0, D =< $9 ->
            {Frac, After2} = digits(tl(After)),
            {Exp, After3} = exponent(After2),
            {{float, Col, list_to_float(Int ++ "." ++ Frac ++ Exp)}, After3};
        [$. | After2] when not AfterDot ->
            %% `1.` is a float too, unless a name follows (`1.method`).
            case After2 of
                [C | _] when (C >= $a andalso C =< $z); C =:= $_ ->
                    {{int, Col, list_to_integer(Int)}, After};
                _ ->
                    {Exp, After3} = exponent(After2),
                    {{float, Col, list_to_float(Int ++ ".0" ++ Exp)}, After3}
            end;
        _ -> {{int, Col, list_to_integer(Int)}, After}
    end.

digits(Text) ->
    {Ds, After} = lists:splitwith(fun(C) -> (C >= $0 andalso C =< $9) orelse C =:= $_ end, Text),
    {[D || D <- Ds, D =/= $_], After}.

exponent([E | Rest]) when E =:= $e; E =:= $E ->
    {Sign, Rest2} = case Rest of
        [$- | R] -> {"-", R};
        [$+ | R] -> {"", R};
        R -> {"", R}
    end,
    {Ds, After} = digits(Rest2),
    {"e" ++ Sign ++ Ds, After};
exponent(Text) -> {"", Text}.

based(Text, Base, Col) ->
    {Ds, After} = lists:splitwith(fun(C) -> is_digit_of(C, Base) orelse C =:= $_ end, Text),
    case [D || D <- Ds, D =/= $_] of
        [] -> fail("Invalid number at column ~b", [Col]);
        Clean -> {{int, Col, list_to_integer(Clean, Base)}, After}
    end.

is_digit_of(C, 16) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f)
                          orelse (C >= $A andalso C =< $F);
is_digit_of(C, 8) -> C >= $0 andalso C =< $7;
is_digit_of(C, 2) -> C =:= $0 orelse C =:= $1.

%% ---------------------------------------------------------------------------
%% Parser. Produces this AST:
%%
%%   {int, V} | {float, V} | {string, Chars} | {name, Name} | {hole}
%%   {ctor, Name, Args | none, Spread | none}   Args: [{Label | none, Expr}]
%%   {tuple, Exprs} | {list, Exprs, Tail | none} | {bits, Segments}
%%   {binop, Op, A, B} | {negate, E} | {'not', E}
%%   {call, Fun, Args} | {access, E, Field} | {index, E, N}
%%   {fn, Params, Statements} | {block, Statements}
%%   {'case', Subjects, Clauses} | {panic, Kind}
%% Statements: {'let', Pattern, Expr} | {expr, Expr}

statements(Tokens, End) -> statements(Tokens, End, []).

statements([], eof, Acc) -> {lists:reverse(Acc), []};
statements([{'}', _} | Rest], '}', Acc) -> {lists:reverse(Acc), Rest};
statements([], '}', _) -> fail("Missing `}`", []);
statements([{'let', _} | Rest], End, Acc) ->
    Rest1 = case Rest of
        [{assert, _} | R] -> R;
        R -> R
    end,
    {Pattern, Rest2} = pattern(Rest1),
    Rest3 = skip_annotation(Rest2),
    Rest4 = expect('=', Rest3),
    {Expr, Rest5} = expr(Rest4),
    statements(Rest5, End, [{'let', Pattern, Expr} | Acc]);
statements(Tokens, End, Acc) ->
    {Expr, Rest} = expr(Tokens),
    statements(Rest, End, [{expr, Expr} | Acc]).

%% `: Type` after a `let` pattern or a parameter.
skip_annotation([{':', _} | Rest]) -> skip_type(Rest);
skip_annotation(Tokens) -> Tokens.

%% Skips a type up to a `,`, `)`, `=` or `{` outside brackets.
skip_type(Tokens) -> skip_type(Tokens, 0).

skip_type([{T, _} | _] = Tokens, 0) when T =:= ','; T =:= ')'; T =:= '='; T =:= '{' ->
    Tokens;
skip_type([{T, _} | Rest], D) when T =:= '('; T =:= '[' -> skip_type(Rest, D + 1);
skip_type([{T, _} | Rest], D) when T =:= ')'; T =:= ']' -> skip_type(Rest, D - 1);
skip_type([_ | Rest], D) -> skip_type(Rest, D);
skip_type([], _) -> [].

expect(Kind, [{Kind, _} | Rest]) -> Rest;
expect(Kind, [Token | _]) ->
    fail("Expected `~ts` at column ~b, found ~ts", [Kind, element(2, Token), describe(Token)]);
expect(Kind, []) -> fail("Expected `~ts` at the end", [Kind]).

describe({Kind, _}) -> io_lib:format("`~ts`", [Kind]);
describe({string, _, _}) -> "a string";
describe({_, _, Value}) when is_list(Value) -> io_lib:format("`~ts`", [Value]);
describe({_, _, Value}) -> io_lib:format("`~p`", [Value]).

expr(Tokens) -> binop(Tokens, 0).

precedence('||') -> 1;
precedence('&&') -> 2;
precedence('==') -> 3;
precedence('!=') -> 3;
precedence(Op) when Op =:= '<'; Op =:= '<='; Op =:= '>'; Op =:= '>=';
                    Op =:= '<.'; Op =:= '<=.'; Op =:= '>.'; Op =:= '>=.' -> 4;
precedence('<>') -> 5;
precedence('|>') -> 6;
precedence(Op) when Op =:= '+'; Op =:= '-'; Op =:= '+.'; Op =:= '-.' -> 7;
precedence(Op) when Op =:= '*'; Op =:= '/'; Op =:= '%'; Op =:= '*.'; Op =:= '/.' -> 8;
precedence(_) -> none.

binop(Tokens, Min) ->
    {Left, Rest} = unary(Tokens),
    binop_loop(Left, Rest, Min).

binop_loop(Left, [{Op, _} | Rest] = Tokens, Min) ->
    case precedence(Op) of
        P when is_integer(P), P > Min ->
            {Right, Rest2} = binop(Rest, P),
            binop_loop({binop, Op, Left, Right}, Rest2, Min);
        _ -> {Left, Tokens}
    end;
binop_loop(Left, Tokens, _) -> {Left, Tokens}.

unary([{'-', _} | Rest]) ->
    {E, Rest2} = unary(Rest),
    {{negate, E}, Rest2};
unary([{'!', _} | Rest]) ->
    {E, Rest2} = unary(Rest),
    {{'not', E}, Rest2};
unary(Tokens) ->
    {E, Rest} = primary(Tokens),
    postfix(E, Rest).

postfix(E, [{'.', _}, {name, _, Field} | Rest]) ->
    postfix({access, E, list_to_atom(Field)}, Rest);
postfix(E, [{'.', _}, {int, _, N} | Rest]) ->
    postfix({index, E, N}, Rest);
postfix({name, Module}, [{'.', _}, {upname, _, Name} | Rest]) ->
    %% A constructor from another module; the module doesn't matter.
    _ = Module,
    constructor(Name, Rest);
postfix(E, [{'(', _} | Rest]) ->
    {Args, Rest2} = arguments(Rest),
    postfix({call, E, Args}, Rest2);
postfix(E, Tokens) -> {E, Tokens}.

%% Call arguments, with optional labels: `(a, label: b)`.
arguments([{')', _} | Rest]) -> {[], Rest};
arguments(Tokens) -> arguments(Tokens, []).

arguments(Tokens, Acc) ->
    {Arg, Rest} = case Tokens of
        [{name, _, Label}, {':', _} | R] ->
            case R of
                %% Shorthand `label:` passes the variable of the same name.
                [{T, _} | _] when T =:= ','; T =:= ')' ->
                    {{list_to_atom(Label), {name, Label}}, R};
                _ ->
                    {E, R2} = expr(R),
                    {{list_to_atom(Label), E}, R2}
            end;
        _ ->
            {E, R} = expr(Tokens),
            {{none, E}, R}
    end,
    case Rest of
        [{',', _}, {')', _} | Rest2] -> {lists:reverse([Arg | Acc]), Rest2};
        [{',', _} | Rest2] -> arguments(Rest2, [Arg | Acc]);
        [{')', _} | Rest2] -> {lists:reverse([Arg | Acc]), Rest2};
        _ -> expect(')', Rest)
    end.

primary([{int, _, V} | Rest]) -> {{int, V}, Rest};
primary([{float, _, V} | Rest]) -> {{float, V}, Rest};
primary([{string, _, S} | Rest]) -> {{string, S}, Rest};
primary([{name, _, N} | Rest]) -> {{name, N}, Rest};
primary([{discard, _, "_"} | Rest]) -> {{hole}, Rest};
primary([{discard, Col, N} | _]) ->
    fail("`~ts` at column ~b is a discarded name and can't be used", [N, Col]);
primary([{upname, _, Name} | Rest]) -> constructor(Name, Rest);
primary([{'#', _}, {'(', _} | Rest]) ->
    {Items, Rest2} = sequence(Rest, ')'),
    {{tuple, Items}, Rest2};
primary([{'[', _} | Rest]) -> list(Rest, []);
primary([{'<<', _} | Rest]) -> bits(Rest, []);
primary([{'{', _} | Rest]) ->
    {Statements, Rest2} = statements(Rest, '}'),
    {{block, Statements}, Rest2};
primary([{'(', _} | Rest]) ->
    %% Not Gleam (it groups with `{}`), but harmless to accept.
    {E, Rest2} = expr(Rest),
    {E, expect(')', Rest2)};
primary([{fn, _}, {'(', _} | Rest]) ->
    {Params, Rest2} = params(Rest, []),
    Rest3 = case Rest2 of
        [{'->', _} | R] -> skip_type(R);
        R -> R
    end,
    Rest4 = expect('{', Rest3),
    {Body, Rest5} = statements(Rest4, '}'),
    {{fn, Params, Body}, Rest5};
primary([{'case', _} | Rest]) ->
    {Subjects, Rest2} = subjects(Rest, []),
    Rest3 = expect('{', Rest2),
    {Clauses, Rest4} = clauses(Rest3, []),
    {{'case', Subjects, Clauses}, Rest4};
primary([{Kind, _} | Rest]) when Kind =:= todo; Kind =:= panic ->
    Rest2 = case Rest of
        [{as, _} | R] -> {_, R2} = expr(R), R2;
        R -> R
    end,
    {{panic, Kind}, Rest2};
primary([Token | _]) ->
    fail("Unexpected ~ts at column ~b", [describe(Token), element(2, Token)]);
primary([]) ->
    fail("The expression is incomplete", []).

%% Comma-separated expressions up to Close, trailing comma allowed.
sequence([{Close, _} | Rest], Close) -> {[], Rest};
sequence(Tokens, Close) -> sequence(Tokens, Close, []).

sequence(Tokens, Close, Acc) ->
    {E, Rest} = expr(Tokens),
    case Rest of
        [{',', _}, {Close, _} | Rest2] -> {lists:reverse([E | Acc]), Rest2};
        [{',', _} | Rest2] -> sequence(Rest2, Close, [E | Acc]);
        [{Close, _} | Rest2] -> {lists:reverse([E | Acc]), Rest2};
        _ -> expect(Close, Rest)
    end.

constructor(Name, [{'(', _} | Rest]) ->
    case Rest of
        [{'..', _} | R] ->
            {Base, R2} = expr(R),
            {Args, R3} = case R2 of
                [{',', _} | R4] -> arguments(R4);
                _ -> {[], expect(')', R2)}
            end,
            {{ctor, Name, Args, Base}, R3};
        _ ->
            {Args, R2} = arguments(Rest),
            {{ctor, Name, Args, none}, R2}
    end;
constructor(Name, Rest) -> {{ctor, Name, none, none}, Rest}.

list([{']', _} | Rest], Acc) -> {{list, lists:reverse(Acc), none}, Rest};
list([{'..', _} | Rest], Acc) ->
    {Tail, Rest2} = expr(Rest),
    Rest3 = case Rest2 of
        [{',', _} | R] -> R;
        R -> R
    end,
    {{list, lists:reverse(Acc), Tail}, expect(']', Rest3)};
list(Tokens, Acc) ->
    {E, Rest} = expr(Tokens),
    case Rest of
        [{',', _} | Rest2] -> list(Rest2, [E | Acc]);
        _ -> list(Rest, [E | Acc])
    end.

%% Bit array segments: `value` or `value:option-option`.
bits([{'>>', _} | Rest], Acc) -> {{bits, lists:reverse(Acc)}, Rest};
bits(Tokens, Acc) ->
    {Value, Rest} = unary(Tokens),
    {Options, Rest2} = case Rest of
        [{':', _} | R] -> segment_options(R, []);
        R -> {[], R}
    end,
    Segment = {Value, Options},
    case Rest2 of
        [{',', _} | Rest3] -> bits(Rest3, [Segment | Acc]);
        _ -> bits(Rest2, [Segment | Acc])
    end.

segment_options(Tokens, Acc) ->
    {Option, Rest} = case Tokens of
        [{name, _, Fun}, {'(', _} | R] when Fun =:= "size"; Fun =:= "unit" ->
            {E, R2} = expr(R),
            {{list_to_atom(Fun), E}, expect(')', R2)};
        [{name, _, Opt} | R] -> {{list_to_atom(Opt)}, R};
        [{int, _, N} | R] -> {{size, {int, N}}, R};
        [Token | _] -> fail("Unexpected ~ts in a bit array segment", [describe(Token)]);
        [] -> fail("The bit array is incomplete", [])
    end,
    case Rest of
        [{'-', _} | Rest2] -> segment_options(Rest2, [Option | Acc]);
        _ -> {lists:reverse([Option | Acc]), Rest}
    end.

params([{')', _} | Rest], Acc) -> {lists:reverse(Acc), Rest};
params(Tokens, Acc) ->
    {Param, Rest} = case Tokens of
        [{name, _, N} | R] -> {{name, N}, R};
        [{discard, _, _} | R] -> {discard, R};
        [Token | _] -> fail("Unexpected ~ts in the parameters", [describe(Token)]);
        [] -> fail("The parameters are incomplete", [])
    end,
    Rest2 = skip_annotation(Rest),
    case Rest2 of
        [{',', _} | Rest3] -> params(Rest3, [Param | Acc]);
        _ -> params(Rest2, [Param | Acc])
    end.

subjects(Tokens, Acc) ->
    {E, Rest} = expr(Tokens),
    case Rest of
        [{',', _} | Rest2] -> subjects(Rest2, [E | Acc]);
        _ -> {lists:reverse([E | Acc]), Rest}
    end.

%% Clauses: `p1, p2 | q1, q2 if guard -> body`.
clauses([{'}', _} | Rest], Acc) -> {lists:reverse(Acc), Rest};
clauses(Tokens, Acc) ->
    {Alternatives, Rest} = alternatives(Tokens, []),
    {Guard, Rest2} = case Rest of
        [{'if', _} | R] -> {G, R2} = expr(R), {G, R2};
        R -> {none, R}
    end,
    Rest3 = expect('->', Rest2),
    {Body, Rest4} = expr(Rest3),
    clauses(Rest4, [{Alternatives, Guard, Body} | Acc]).

alternatives(Tokens, Acc) ->
    {Patterns, Rest} = pattern_list(Tokens, []),
    case Rest of
        [{'|', _} | Rest2] -> alternatives(Rest2, [Patterns | Acc]);
        _ -> {lists:reverse([Patterns | Acc]), Rest}
    end.

pattern_list(Tokens, Acc) ->
    {P, Rest} = pattern(Tokens),
    case Rest of
        [{',', _} | Rest2] -> pattern_list(Rest2, [P | Acc]);
        _ -> {lists:reverse([P | Acc]), Rest}
    end.

%% Patterns:
%%   {pint, V} | {pfloat, V} | {pstring, Chars} | {pvar, Name} | pdiscard
%%   {pconcat, Chars, Pattern} | {ptuple, Ps} | {plist, Ps, Tail | none}
%%   {pctor, Name, Args, Spread :: boolean()} | {pas, Pattern, Name}
pattern(Tokens) ->
    {P, Rest} = pattern_primary(Tokens),
    case Rest of
        [{as, _}, {name, _, Name} | Rest2] -> {{pas, P, Name}, Rest2};
        _ -> {P, Rest}
    end.

pattern_primary([{int, _, V} | Rest]) -> {{pint, V}, Rest};
pattern_primary([{float, _, V} | Rest]) -> {{pfloat, V}, Rest};
pattern_primary([{'-', _}, {int, _, V} | Rest]) -> {{pint, -V}, Rest};
pattern_primary([{'-', _}, {float, _, V} | Rest]) -> {{pfloat, -V}, Rest};
pattern_primary([{string, _, S}, {'<>', _} | Rest]) ->
    {P, Rest2} = pattern_primary(Rest),
    {{pconcat, S, P}, Rest2};
pattern_primary([{string, _, S} | Rest]) -> {{pstring, S}, Rest};
pattern_primary([{name, _, _}, {'.', _}, {upname, _, Name} | Rest]) ->
    pattern_ctor(Name, Rest);
pattern_primary([{name, _, N} | Rest]) -> {{pvar, N}, Rest};
pattern_primary([{discard, _, _} | Rest]) -> {pdiscard, Rest};
pattern_primary([{upname, _, Name} | Rest]) -> pattern_ctor(Name, Rest);
pattern_primary([{'#', _}, {'(', _} | Rest]) ->
    {Ps, Rest2} = pattern_sequence(Rest, ')', []),
    {{ptuple, Ps}, Rest2};
pattern_primary([{'[', _} | Rest]) -> pattern_list_literal(Rest, []);
pattern_primary([Token | _]) ->
    fail("Unexpected ~ts in a pattern at column ~b", [describe(Token), element(2, Token)]);
pattern_primary([]) -> fail("The pattern is incomplete", []).

pattern_sequence([{Close, _} | Rest], Close, Acc) -> {lists:reverse(Acc), Rest};
pattern_sequence(Tokens, Close, Acc) ->
    {P, Rest} = pattern(Tokens),
    case Rest of
        [{',', _} | Rest2] -> pattern_sequence(Rest2, Close, [P | Acc]);
        _ -> pattern_sequence(Rest, Close, [P | Acc])
    end.

pattern_list_literal([{']', _} | Rest], Acc) -> {{plist, lists:reverse(Acc), none}, Rest};
pattern_list_literal([{'..', _} | Rest], Acc) ->
    {Tail, Rest2} = case Rest of
        [{']', _} | _] -> {pdiscard, Rest};
        _ -> pattern(Rest)
    end,
    {{plist, lists:reverse(Acc), Tail}, expect(']', Rest2)};
pattern_list_literal(Tokens, Acc) ->
    {P, Rest} = pattern(Tokens),
    case Rest of
        [{',', _} | Rest2] -> pattern_list_literal(Rest2, [P | Acc]);
        _ -> pattern_list_literal(Rest, [P | Acc])
    end.

pattern_ctor(Name, [{'(', _} | Rest]) -> pattern_ctor_args(Name, Rest, []);
pattern_ctor(Name, Rest) -> {{pctor, Name, [], false}, Rest}.

pattern_ctor_args(Name, [{')', _} | Rest], Acc) ->
    {{pctor, Name, lists:reverse(Acc), false}, Rest};
pattern_ctor_args(Name, [{'..', _} | Rest], Acc) ->
    Rest2 = case Rest of
        [{',', _} | R] -> R;
        R -> R
    end,
    {{pctor, Name, lists:reverse(Acc), true}, expect(')', Rest2)};
pattern_ctor_args(Name, Tokens, Acc) ->
    {Arg, Rest} = case Tokens of
        [{name, _, Label}, {':', _} | R] ->
            case R of
                [{T, _} | _] when T =:= ','; T =:= ')' ->
                    {{list_to_atom(Label), {pvar, Label}}, R};
                _ ->
                    {P, R2} = pattern(R),
                    {{list_to_atom(Label), P}, R2}
            end;
        _ ->
            {P, R} = pattern(Tokens),
            {{none, P}, R}
    end,
    case Rest of
        [{',', _} | Rest2] -> pattern_ctor_args(Name, Rest2, [Arg | Acc]);
        _ -> pattern_ctor_args(Name, Rest, [Arg | Acc])
    end.

%% ---------------------------------------------------------------------------
%% Translation to Erlang abstract syntax.
%%
%% Env: names (the frame's bindings), vars (#{GleamName => ErlangVar} for
%% names bound in the expression itself) and module.

-define(L, 1).

compile_statements([], _) -> [{atom, ?L, nil}];
compile_statements([{expr, E}], Env) -> [expr_form(E, Env)];
compile_statements([{expr, E} | Rest], Env) ->
    [expr_form(E, Env) | compile_statements(Rest, Env)];
compile_statements([{'let', Pattern, E}], Env) ->
    %% A `let` at the end returns its value, like in Gleam.
    Value = expr_form(E, Env),
    {PForm, _} = pattern_form(Pattern, Env, #{}),
    [{match, ?L, PForm, Value}];
compile_statements([{'let', Pattern, E} | Rest], Env) ->
    Value = expr_form(E, Env),
    {PForm, Bound} = pattern_form(Pattern, Env, #{}),
    Env2 = bind(Env, Bound),
    [{match, ?L, PForm, Value} | compile_statements(Rest, Env2)].

bind(#{vars := Vars} = Env, Bound) -> Env#{vars => maps:merge(Vars, Bound)}.

fresh(Name) ->
    list_to_atom("Gleam_" ++ Name ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))).

lookup(Name, #{vars := Vars, names := Names}) ->
    case maps:find(Name, Vars) of
        {ok, Var} -> {ok, Var};
        error ->
            case maps:find(list_to_atom(Name), Names) of
                {ok, {Var, _}} -> {ok, Var};
                error -> error
            end
    end.

is_variable(Name, Env) -> lookup(Name, Env) =/= error.

expr_form({int, V}, _) -> {integer, ?L, V};
expr_form({float, V}, _) -> {float, ?L, V};
expr_form({string, Chars}, _) -> string_form(Chars);
expr_form({hole}, _) -> fail("`_` can only stand for an argument in a pipe", []);
expr_form({name, Name}, Env) ->
    case lookup(Name, Env) of
        {ok, Var} -> {var, ?L, Var};
        error ->
            case current_module_function(Name, Env) of
                {ok, Fun} -> Fun;
                error -> throw({unknown_variable, list_to_atom(Name)})
            end
    end;
expr_form({ctor, Name, Args, Spread}, Env) -> ctor_form(Name, Args, Spread, Env);
expr_form({tuple, Items}, Env) -> {tuple, ?L, [expr_form(I, Env) || I <- Items]};
expr_form({list, Items, Tail}, Env) ->
    TailForm = case Tail of
        none -> {nil, ?L};
        T -> expr_form(T, Env)
    end,
    lists:foldr(fun(I, Acc) -> {cons, ?L, expr_form(I, Env), Acc} end, TailForm, Items);
expr_form({bits, Segments}, Env) ->
    {bin, ?L, [segment_form(S, Env) || S <- Segments]};
expr_form({binop, '|>', Left, Right}, Env) -> expr_form(pipe(Left, Right), Env);
expr_form({binop, Op, A, B}, Env) -> binop_form(Op, expr_form(A, Env), expr_form(B, Env));
expr_form({negate, E}, Env) -> {op, ?L, '-', expr_form(E, Env)};
expr_form({'not', E}, Env) -> {op, ?L, 'not', expr_form(E, Env)};
expr_form({access, {name, Module}, Name}, Env) ->
    case is_variable(Module, Env) of
        true -> helper(field, [expr_form({name, Module}, Env), {atom, ?L, Name}]);
        false -> function_reference(resolve_module(Module), Name)
    end;
expr_form({access, E, Field}, Env) ->
    helper(field, [expr_form(E, Env), {atom, ?L, Field}]);
expr_form({index, E, N}, Env) ->
    helper(field, [expr_form(E, Env), {integer, ?L, N}]);
expr_form({call, Fun, Args}, Env) -> call_form(Fun, Args, Env);
expr_form({fn, Params, Body}, Env) ->
    {Forms, Bound} = lists:mapfoldl(
        fun(discard, Acc) -> {{var, ?L, '_'}, Acc};
           ({name, N}, Acc) -> V = fresh(N), {{var, ?L, V}, Acc#{N => V}}
        end, #{}, Params),
    {'fun', ?L, {clauses, [{clause, ?L, Forms, [], compile_statements(Body, bind(Env, Bound))}]}};
expr_form({block, Statements}, Env) -> {block, ?L, compile_statements(Statements, Env)};
expr_form({'case', Subjects, Clauses}, Env) -> case_form(Subjects, Clauses, Env);
expr_form({panic, Kind}, _) ->
    {call, ?L, {remote, ?L, {atom, ?L, erlang}, {atom, ?L, error}}, [{atom, ?L, Kind}]}.

string_form(Chars) ->
    {bin, ?L, [{bin_element, ?L, {string, ?L, Chars}, default, [utf8]}]}.

helper(Name, Args) ->
    {call, ?L, {remote, ?L, {atom, ?L, gleam_dap_eval_ffi}, {atom, ?L, Name}}, Args}.

binop_form('+', A, B) -> {op, ?L, '+', A, B};
binop_form('-', A, B) -> {op, ?L, '-', A, B};
binop_form('*', A, B) -> {op, ?L, '*', A, B};
binop_form('+.', A, B) -> {op, ?L, '+', A, B};
binop_form('-.', A, B) -> {op, ?L, '-', A, B};
binop_form('*.', A, B) -> {op, ?L, '*', A, B};
binop_form('/', A, B) -> helper(divide_int, [A, B]);
binop_form('%', A, B) -> helper(remainder_int, [A, B]);
binop_form('/.', A, B) -> helper(divide_float, [A, B]);
binop_form('==', A, B) -> {op, ?L, '=:=', A, B};
binop_form('!=', A, B) -> {op, ?L, '=/=', A, B};
binop_form(Op, A, B) when Op =:= '<'; Op =:= '<.' -> {op, ?L, '<', A, B};
binop_form(Op, A, B) when Op =:= '<='; Op =:= '<=.' -> {op, ?L, '=<', A, B};
binop_form(Op, A, B) when Op =:= '>'; Op =:= '>.' -> {op, ?L, '>', A, B};
binop_form(Op, A, B) when Op =:= '>='; Op =:= '>=.' -> {op, ?L, '>=', A, B};
binop_form('&&', A, B) -> {op, ?L, 'andalso', A, B};
binop_form('||', A, B) -> {op, ?L, 'orelse', A, B};
binop_form('<>', A, B) -> helper(append, [A, B]).

%% `a |> f(b)` is `f(a, b)`, `a |> f(b, _)` is `f(b, a)`, `a |> f` is `f(a)`.
pipe(Left, {call, Fun, Args}) ->
    case lists:any(fun({_, {hole}}) -> true; (_) -> false end, Args) of
        true ->
            {call, Fun, [case A of {L, {hole}} -> {L, Left}; _ -> A end || A <- Args]};
        false ->
            {call, Fun, [{none, Left} | Args]}
    end;
pipe(Left, {ctor, Name, none, none}) -> {ctor, Name, [{none, Left}], none};
pipe(Left, {ctor, Name, Args, none}) ->
    {call, _, Piped} = pipe(Left, {call, none, Args}),
    {ctor, Name, Piped, none};
pipe(Left, Right) -> {call, Right, [{none, Left}]}.

call_form({ctor, Name, none, none}, Args, Env) -> ctor_form(Name, Args, none, Env);
call_form(Fun, Args, Env) ->
    case [L || {L, _} <- Args, L =/= none] of
        [] -> ok;
        [Label | _] ->
            fail("Labelled arguments (`~ts:`) can't be checked against the function here; "
                 "pass the arguments in order without labels", [Label])
    end,
    ArgForms = [expr_form(E, Env) || {_, E} <- Args],
    case Fun of
        {access, {name, Module}, Name} ->
            case is_variable(Module, Env) of
                true ->
                    {call, ?L, helper(field, [expr_form({name, Module}, Env), {atom, ?L, Name}]), ArgForms};
                false ->
                    {call, ?L, {remote, ?L, {atom, ?L, resolve_module(Module)}, {atom, ?L, Name}}, ArgForms}
            end;
        {name, Name} ->
            case lookup(Name, Env) of
                {ok, Var} -> {call, ?L, {var, ?L, Var}, ArgForms};
                error ->
                    case maps:get(module, Env) of
                        undefined -> throw({unknown_variable, list_to_atom(Name)});
                        Module ->
                            {call, ?L, {remote, ?L, {atom, ?L, binary_to_atom(Module, utf8)},
                                        {atom, ?L, list_to_atom(Name)}}, ArgForms}
                    end
            end;
        _ -> {call, ?L, expr_form(Fun, Env), ArgForms}
    end.

%% A public function of the frame's module, used as a value.
current_module_function(Name, #{module := Module}) when is_binary(Module) ->
    Mod = binary_to_atom(Module, utf8),
    Fun = list_to_atom(Name),
    case [A || {F, A} <- exports(Mod), F =:= Fun] of
        [Arity] -> {ok, {'fun', ?L, {function, {atom, ?L, Mod}, {atom, ?L, Fun}, {integer, ?L, Arity}}}};
        _ -> error
    end;
current_module_function(_, _) -> error.

function_reference(Mod, Fun) ->
    case [A || {F, A} <- exports(Mod), F =:= Fun] of
        [Arity] -> {'fun', ?L, {function, {atom, ?L, Mod}, {atom, ?L, Fun}, {integer, ?L, Arity}}};
        [] -> fail("~ts has no public function ~ts", [gleam_module(Mod), Fun]);
        _ -> fail("~ts.~ts has several arities; call it instead", [gleam_module(Mod), Fun])
    end.

exports(Mod) ->
    [{binary_to_atom(F, utf8), A} || {F, A} <- gleam_dap_launch_ffi:module_exports(atom_to_binary(Mod, utf8))].

gleam_module(Mod) -> string:replace(atom_to_list(Mod), "@", "/", all).

resolve_module(Name) -> gleam_dap_eval_ffi:resolve_module(list_to_atom(Name)).

segment_form({Value, Options}, Env) ->
    {Size, Types} = lists:foldl(
        fun({size, E}, {_, Ts}) -> {expr_form(E, Env), Ts};
           ({unit, {int, N}}, {S, Ts}) -> {S, Ts ++ [{unit, N}]};
           ({unit, _}, _) -> fail("unit must be an integer", []);
           ({T}, {S, Ts}) -> {S, Ts ++ [segment_type(T)]}
        end, {default, []}, Options),
    ValueForm = case Value of
        {string, Chars} -> {string, ?L, Chars};
        _ -> expr_form(Value, Env)
    end,
    TypeList = case {Value, Types} of
        {{string, _}, []} -> [utf8];
        {_, []} -> default;
        _ -> Types
    end,
    {bin_element, ?L, ValueForm, Size, TypeList}.

segment_type(bits) -> bitstring;
segment_type(bit_array) -> bitstring;
segment_type(bytes) -> binary;
segment_type(T) when T =:= int; T =:= float; T =:= utf8; T =:= utf16; T =:= utf32;
                     T =:= big; T =:= little; T =:= native; T =:= signed;
                     T =:= unsigned; T =:= binary; T =:= bitstring ->
    T;
segment_type(T) -> fail("Unknown bit array option ~ts", [T]).

%% Constructors are atoms (no fields) or tagged tuples. Labels come from
%% the record definitions Gleam generates.
ctor_form("True", none, none, _) -> {atom, ?L, true};
ctor_form("False", none, none, _) -> {atom, ?L, false};
ctor_form("Nil", none, none, _) -> {atom, ?L, nil};
ctor_form(Name, none, none, _) -> {atom, ?L, tag(Name)};
ctor_form(Name, Args, none, Env) ->
    Tag = tag(Name),
    Ordered = order_args(Name, Tag, Args),
    {tuple, ?L, [{atom, ?L, Tag} | [expr_form(E, Env) || E <- Ordered]]};
ctor_form(Name, Args, Base, Env) ->
    %% `Name(..base, label: value)`: the fields are found when it runs.
    Updates = lists:foldr(
        fun({none, _}, _) -> fail("A record update needs labels, like `~ts(..x, label: value)`", [Name]);
           ({Label, E}, Acc) -> {cons, ?L, {tuple, ?L, [{atom, ?L, Label}, expr_form(E, Env)]}, Acc}
        end, {nil, ?L}, Args),
    helper(update_record, [expr_form(Base, Env), Updates]).

tag(Name) ->
    case constructor_tag(Name) of
        {ok, Tag} -> Tag;
        error -> list_to_atom(snake_case(Name))
    end.

%% The tag of a constructor of the debugged program, by its name.
constructor_tag(Name) ->
    Bin = list_to_binary(Name),
    Labels = persistent_term:get(gleam_dap_labels, #{}),
    case [T || {{T, _}, {C, _}} <- maps:to_list(Labels), C =:= Bin] of
        [Tag | _] -> {ok, binary_to_atom(Tag, utf8)};
        [] -> error
    end.

snake_case([C | Rest]) -> [lower(C) | snake_rest(Rest)].
snake_rest([C | Rest]) when C >= $A, C =< $Z -> [$_, lower(C) | snake_rest(Rest)];
snake_rest([C | Rest]) -> [C | snake_rest(Rest)];
snake_rest([]) -> [].
lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.

fields(Tag, Arity) ->
    Labels = persistent_term:get(gleam_dap_labels, #{}),
    case maps:get({atom_to_binary(Tag, utf8), Arity}, Labels, undefined) of
        {_, Fields} -> [binary_to_atom(F, utf8) || F <- Fields];
        undefined -> []
    end.

%% Positional arguments first, then labelled ones in their field's place.
order_args(Name, Tag, Args) ->
    case [L || {L, _} <- Args, L =/= none] of
        [] -> [E || {_, E} <- Args];
        _ ->
            Fields = fields(Tag, length(Args)),
            Fields =:= [] andalso fail("~ts has no labelled fields", [Name]),
            Positional = [E || {none, E} <- Args],
            Labelled = [{L, E} || {L, E} <- Args, L =/= none],
            {_, Rest} = lists:split(length(Positional), Fields),
            Positional ++ [case lists:keyfind(F, 1, Labelled) of
                               {_, E} -> E;
                               false -> fail("~ts is missing the field ~ts", [Name, F])
                           end || F <- Rest]
    end.

%% `case`. Alternatives become separate clauses. With a guard, the clauses
%% are tried one after another in funs, since a Gleam guard can do more
%% than an Erlang one.
case_form(Subjects, Clauses, Env) ->
    Subject = case Subjects of
        [One] -> expr_form(One, Env);
        Many -> {tuple, ?L, [expr_form(S, Env) || S <- Many]}
    end,
    Compiled = [compile_clause(length(Subjects), Alts, Guard, Body, Env)
                || {Alts, Guard, Body} <- Clauses],
    case lists:all(fun({_, none, _}) -> true; (_) -> false end, lists:append(Compiled)) of
        true ->
            {'case', ?L, Subject,
             [{clause, ?L, [P], [], [B]} || {P, none, B} <- lists:append(Compiled)]};
        false ->
            %% F1 = fun() -> case S of P1 -> (guard -> body | F2()); _ -> F2() end end,
            %% bound from the last clause back, then F1().
            Var = {var, ?L, fresh("subject")},
            All = lists:append(Compiled),
            FunVars = [{var, ?L, fresh("clause")} || _ <- All],
            NoMatch = {'fun', ?L, {clauses, [{clause, ?L, [], [],
                [{call, ?L, {remote, ?L, {atom, ?L, erlang}, {atom, ?L, error}},
                  [{tuple, ?L, [{atom, ?L, case_clause}, Var]}]}]}]}},
            Nexts = tl(FunVars) ++ [none],
            Bound = lists:reverse(lists:zipwith3(
                fun({P, Guard, B}, FunVar, Next) ->
                    Fallthrough = case Next of
                        none -> {call, ?L, NoMatch, []};
                        _ -> {call, ?L, Next, []}
                    end,
                    Then = case Guard of
                        none -> B;
                        G -> {'case', ?L, G, [{clause, ?L, [{atom, ?L, true}], [], [B]},
                                              {clause, ?L, [{var, ?L, '_'}], [], [Fallthrough]}]}
                    end,
                    {match, ?L, FunVar,
                     {'fun', ?L, {clauses, [{clause, ?L, [], [],
                         [{'case', ?L, Var, [{clause, ?L, [P], [], [Then]},
                                             {clause, ?L, [{var, ?L, '_'}], [], [Fallthrough]}]}]}]}}}
                end, All, FunVars, Nexts)),
            {block, ?L, [{match, ?L, Var, Subject} | Bound] ++ [{call, ?L, hd(FunVars), []}]}
    end.

%% Each alternative binds the same names to the same Erlang variables.
compile_clause(Count, Alternatives, Guard, Body, Env) ->
    {Forms, Bound} = lists:mapfoldl(
        fun(Patterns, Acc) ->
            length(Patterns) =:= Count orelse
                fail("This case has ~b subjects but a clause has ~b patterns", [Count, length(Patterns)]),
            {PForms, Acc2} = lists:mapfoldl(fun(P, A) -> pattern_form(P, Env, A) end, Acc, Patterns),
            Form = case PForms of
                [One] -> One;
                Many -> {tuple, ?L, Many}
            end,
            {Form, Acc2}
        end, #{}, Alternatives),
    Env2 = bind(Env, Bound),
    GuardForm = case Guard of
        none -> none;
        G -> expr_form(G, Env2)
    end,
    BodyForm = expr_form(Body, Env2),
    [{F, GuardForm, BodyForm} || F <- Forms].

%% Returns {Form, Bound}, adding names bound by the pattern to Bound.
pattern_form({pint, V}, _, B) -> {{integer, ?L, V}, B};
pattern_form({pfloat, V}, _, B) -> {{float, ?L, V}, B};
pattern_form({pstring, Chars}, _, B) -> {string_form(Chars), B};
pattern_form(pdiscard, _, B) -> {{var, ?L, '_'}, B};
pattern_form({pvar, Name}, _, B) ->
    case maps:find(Name, B) of
        {ok, Var} -> {{var, ?L, Var}, B};
        error -> Var = fresh(Name), {{var, ?L, Var}, B#{Name => Var}}
    end;
pattern_form({pas, P, Name}, Env, B) ->
    {Form, B2} = pattern_form(P, Env, B),
    {VarForm, B3} = pattern_form({pvar, Name}, Env, B2),
    {{match, ?L, Form, VarForm}, B3};
pattern_form({pconcat, Prefix, P}, Env, B) ->
    {RestForm, B2} = pattern_form(P, Env, B),
    {{bin, ?L, [{bin_element, ?L, {string, ?L, Prefix}, default, [utf8]},
                {bin_element, ?L, RestForm, default, [binary]}]}, B2};
pattern_form({ptuple, Ps}, Env, B) ->
    {Forms, B2} = lists:mapfoldl(fun(P, A) -> pattern_form(P, Env, A) end, B, Ps),
    {{tuple, ?L, Forms}, B2};
pattern_form({plist, Ps, Tail}, Env, B) ->
    {Forms, B2} = lists:mapfoldl(fun(P, A) -> pattern_form(P, Env, A) end, B, Ps),
    {TailForm, B3} = case Tail of
        none -> {{nil, ?L}, B2};
        T -> pattern_form(T, Env, B2)
    end,
    {lists:foldr(fun(F, Acc) -> {cons, ?L, F, Acc} end, TailForm, Forms), B3};
pattern_form({pctor, "True", [], false}, _, B) -> {{atom, ?L, true}, B};
pattern_form({pctor, "False", [], false}, _, B) -> {{atom, ?L, false}, B};
pattern_form({pctor, "Nil", [], false}, _, B) -> {{atom, ?L, nil}, B};
pattern_form({pctor, Name, [], false}, _, B) -> {{atom, ?L, tag(Name)}, B};
pattern_form({pctor, Name, Args, Spread}, Env, B) ->
    Tag = tag(Name),
    HasLabels = lists:any(fun({L, _}) -> L =/= none end, Args),
    Patterns = case {HasLabels, Spread} of
        {false, false} -> [P || {_, P} <- Args];
        _ ->
            Fields = spread_fields(Name, Tag, Args, Spread),
            Positional = [P || {none, P} <- Args],
            Labelled = [{L, P} || {L, P} <- Args, L =/= none],
            {_, Rest} = lists:split(min(length(Positional), length(Fields)), Fields),
            Positional ++ [case lists:keyfind(F, 1, Labelled) of
                               {_, P} -> P;
                               false -> pdiscard
                           end || F <- Rest]
    end,
    {Forms, B2} = lists:mapfoldl(fun(P, A) -> pattern_form(P, Env, A) end, B, Patterns),
    {{tuple, ?L, [{atom, ?L, Tag} | Forms]}, B2}.

%% The fields of a constructor matched with labels or `..`.
spread_fields(Name, Tag, Args, Spread) ->
    Labels = persistent_term:get(gleam_dap_labels, #{}),
    TagBin = atom_to_binary(Tag, utf8),
    Candidates = [[binary_to_atom(F, utf8) || F <- Fs]
                  || {{T, Arity}, {_, Fs}} <- maps:to_list(Labels),
                     T =:= TagBin, Spread orelse Arity =:= length(Args)],
    Wanted = [L || {L, _} <- Args, L =/= none],
    case [Fs || Fs <- Candidates, Wanted -- Fs =:= []] of
        [Fields | _] -> Fields;
        [] -> fail("Can't find the fields of ~ts", [Name])
    end.
