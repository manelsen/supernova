-module(supernova_exception_guard_ffi).
-export([run/1]).

%% Run a zero-arity fun, converting any exception into a typed error.
run(Fun) ->
    try Fun(), {ok, nil}
    catch
        Class:Reason:Stack ->
            {error, unicode:characters_to_binary(
                io_lib:format("~p:~p~n~p", [Class, Reason, Stack]))}
    end.
