-module(inbox_test_ffi).
-export([message_queue_len/1]).

message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> N;
        undefined -> 0
    end.
