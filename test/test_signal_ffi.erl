-module(test_signal_ffi).
-export([send_shutdown_exit/1, kill_pid/1]).

send_shutdown_exit(Pid) ->
  erlang:exit(Pid, shutdown),
  nil.

kill_pid(Pid) ->
  erlang:exit(Pid, kill),
  nil.
