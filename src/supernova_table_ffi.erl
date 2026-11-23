-module(supernova_table_ffi).
-export([get/2, put/3, delete/2]).

%% Named public ETS tables, read concurrently by any process. Each table is
%% owned by a process of its own that only holds it, so it outlives whoever
%% touched it first. A put on a table that could not be made does nothing:
%% these tables are views of what is on disk, not the truth.

get(Table, Key) ->
    case ets:whereis(Table) of
        undefined -> {error, nil};
        _ ->
            case ets:lookup(Table, Key) of
                [{_, Value}] -> {ok, Value};
                [] -> {error, nil}
            end
    end.

put(Table, Key, Value) ->
    ensure(Table),
    case ets:whereis(Table) of
        undefined -> nil;
        _ -> ets:insert(Table, {Key, Value}), nil
    end.

delete(Table, Key) ->
    case ets:whereis(Table) of
        undefined -> nil;
        _ -> ets:delete(Table, Key), nil
    end.

ensure(Table) ->
    case ets:whereis(Table) of
        undefined ->
            Parent = self(),
            Ref = make_ref(),
            spawn(fun() ->
                Created = try
                    ets:new(Table, [named_table, public, set,
                                    {read_concurrency, true},
                                    {write_concurrency, true}]),
                    true
                catch error:badarg -> false
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
