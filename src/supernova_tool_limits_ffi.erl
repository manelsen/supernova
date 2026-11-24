-module(supernova_tool_limits_ffi).
-export([get/1]).

get(Key) ->
    try {ok, persistent_term:get(Key)}
    catch error:badarg -> {error, nil}
    end.
