-module(gleam_dap_debug_ffi).
-export([break/0]).

%% Under gleam-dap the adapter interprets this module and puts a breakpoint
%% in `stop_here/0`. When it stops there, it runs on to the caller's next
%% line and reports the stop there. Outside the debugger this does nothing.
break() ->
    case whereis(gleam_dap_session) of
        undefined -> nil;
        _ -> stop_here()
    end.

stop_here() ->
    nil.
