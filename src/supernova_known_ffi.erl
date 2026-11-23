-module(supernova_known_ffi).
-export([get/1, put/2, delete/1]).

%% Facts that change rarely (an agent's forget epoch, that a core is named),
%% read on every message by every chat. An ETS table read concurrently by
%% any process. (persistent_term was tried first: each put scans every
%% process, and two puts per agent at the start of a load stalled the VM.)
-define(TABLE, supernova_known).

get(Key) ->
    case ets:whereis(?TABLE) of
        undefined -> {error, nil};
        _ ->
            case ets:lookup(?TABLE, Key) of
                [{_, Value}] -> {ok, Value};
                [] -> {error, nil}
            end
    end.

put(Key, Value) ->
    ensure_table(),
    %% A cache: if the table could not be made, the value is not kept and the
    %% next read goes to the disk, instead of crashing the caller.
    case ets:whereis(?TABLE) of
        undefined -> nil;
        _ -> ets:insert(?TABLE, {Key, Value}), nil
    end.

delete(Key) ->
    case ets:whereis(?TABLE) of
        undefined -> nil;
        _ -> ets:delete(?TABLE, Key), nil
    end.

%% The table needs an owner that outlives whoever touched it first: a
%% process of its own, started once, that only holds it.
ensure_table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            Parent = self(),
            Ref = make_ref(),
            spawn(fun() ->
                Created = try
                    ets:new(?TABLE, [named_table, public, set,
                                     {read_concurrency, true},
                                     {write_concurrency, true}]),
                    true
                catch error:badarg -> false  %% another process won the race
                end,
                Parent ! {Ref, done},
                case Created of
                    true -> receive stop -> ok end;
                    false -> ok
                end
            end),
            receive {Ref, done} -> ok after 5000 -> ok end;
        _ -> ok
    end.
