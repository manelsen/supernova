-module(supernova_global_ffi).
-export([global_put/2, global_get/1, global_has/1, global_erase/1, safe_is_process_alive/1, safe_println/1, global_lookup/1]).

%% Shared global storage using persistent_term.
%% Unlike process dictionary, these are accessible from ALL processes.

global_put(Key, Value) ->
    persistent_term:put(Key, Value),
    nil.

global_get(Key) ->
    try persistent_term:get(Key)
    catch
        error:badarg -> undefined
    end.

global_has(Key) ->
    try
        _ = persistent_term:get(Key),
        true
    catch
        error:badarg -> false
    end.

global_erase(Key) ->
    persistent_term:erase(Key),
    nil.

safe_is_process_alive(Pid) ->
    try erlang:is_process_alive(Pid) of
        Result -> Result
    catch
        error:badarg -> false;
        error:system_limit -> false;
        error:badarith -> false;
        error:_ -> false
    end.

%% Print a line, ignoring an io device that is gone: a long-lived actor (the
%% tracer) must not crash because the process that started it, and owned its
%% group leader, has ended.
safe_println(Line) ->
    try io:put_chars([Line, $\n]) of
        _ -> nil
    catch
        _:_ -> nil
    end.

%% Read a key in one step: {ok, Value} or {error, nil}. Checking presence and
%% then reading could race with an erase between the two calls.
global_lookup(Key) ->
    case persistent_term:get(Key, '$supernova_absent') of
        '$supernova_absent' -> {error, nil};
        Value -> {ok, Value}
    end.
