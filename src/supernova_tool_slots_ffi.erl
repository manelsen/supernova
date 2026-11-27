-module(supernova_tool_slots_ffi).
-export([take/2, give_back/1, count/1]).

%% Slots of tool calls in flight (PRD-F, F-03): one counter per key, in a
%% public ETS table, changed with update_counter. Taking and giving back a
%% slot never goes through a process.
%%
%% The table belongs to a small process that only keeps it alive; it is
%% started the first time a slot is needed.

-define(TABLE, supernova_tool_slots).

%% Take one slot of Key if fewer than Limit are taken. true when taken.
take(Key, Limit) ->
    ensure_table(),
    ets:insert_new(?TABLE, {Key, 0}),
    take_free(Key, Limit).

%% Compare and swap: the counter only moves from N to N + 1 while N is
%% under Limit, so a refused try never shows as one more running call.
take_free(Key, Limit) ->
    case ets:lookup(?TABLE, Key) of
        [{_, N}] when N < Limit ->
            Swap = [{{Key, N}, [], [{const, {Key, N + 1}}]}],
            case ets:select_replace(?TABLE, Swap) of
                1 -> true;
                0 -> take_free(Key, Limit)
            end;
        _ -> false
    end.

give_back(Key) ->
    ensure_table(),
    ets:update_counter(?TABLE, Key, {2, -1}, {Key, 1}),
    nil.

count(Key) ->
    ensure_table(),
    case ets:lookup(?TABLE, Key) of
        [{_, N}] -> N;
        [] -> 0
    end.

ensure_table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            Parent = self(),
            Ref = make_ref(),
            spawn(fun() ->
                Created =
                    try
                        ets:new(?TABLE, [named_table, public, set,
                                         {write_concurrency, true},
                                         {read_concurrency, true}]),
                        true
                    catch
                        error:badarg -> false
                    end,
                Parent ! {Ref, ok},
                case Created of
                    true -> receive stop -> ok end;
                    false -> ok
                end
            end),
            receive {Ref, ok} -> ok after 1000 -> ok end;
        _ -> ok
    end.
