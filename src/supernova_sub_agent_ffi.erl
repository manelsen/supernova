-module(supernova_sub_agent_ffi).
-export([unique_int/0]).

unique_int() ->
  erlang:unique_integer([positive]).
