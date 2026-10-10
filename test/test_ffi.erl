-module(test_ffi).
-export([to_dynamic/1, make_pid/0, make_fun/0, bits/0, improper/0, map/0,
         write_file/2, get_env/1]).

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
