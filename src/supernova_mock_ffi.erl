-module(supernova_mock_ffi).
-export([network_fail_once/1]).

%% Return true exactly once per key in the calling process. Used by the mock
%% provider to simulate a network failure followed by a successful retry.
network_fail_once(Key) ->
    case get({mock_network_fail_once, Key}) of
        undefined ->
            put({mock_network_fail_once, Key}, true),
            true;
        _ -> false
    end.
