-module(supernova_syscall_ffi).
-export([unique_id/0]).

unique_id() ->
    erlang:unique_integer([positive, monotonic]).
