-module(inbox_test_ffi).
-export([installed/0]).

installed() ->
    lists:member(supernova_signal_ffi, gen_event:which_handlers(erl_signal_server)).
