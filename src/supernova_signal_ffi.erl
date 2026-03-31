-module(supernova_signal_ffi).
-export([wait_for_shutdown/0]).

%% Trap exit signals and block until SIGTERM/shutdown is received.
%% When the BEAM receives SIGTERM, it sends an EXIT signal to processes
%% that have trap_exit enabled.
wait_for_shutdown() ->
    process_flag(trap_exit, true),
    receive
        {'EXIT', _, shutdown} -> nil;
        {'EXIT', _, {shutdown, _}} -> nil;
        {'EXIT', _, _} -> nil
    end.
