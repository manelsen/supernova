-module(supernova_mock_ffi).
-export([network_fail_once/1, clock_set/1, clock_now/0]).

%% Return true exactly once per key in the calling process. Used by the mock
%% provider to simulate a network failure followed by a successful retry.
clock_set(Timestamp) ->
    persistent_term:put({supernova_mock_clock}, Timestamp).

clock_now() ->
    persistent_term:get({supernova_mock_clock}, 0).

network_fail_once(Key) ->
    case get({mock_network_fail_once, Key}) of
        undefined ->
            put({mock_network_fail_once, Key}, true),
            true;
        _ -> false
    end.
