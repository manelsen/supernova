-module(supernova_stress_ffi).
-export([vm_snapshot/1, now_ms/0, mono_ms/0, rand_int/1, halt/1, dir_bytes/1,
         open_client/1]).

%% {Processes, MemoryBytes, MaxMessageQueue, RunQueue} of the whole VM.
%% Exclude (the test's own collector, which queues results on purpose) is
%% left out of the queue maximum.
vm_snapshot(Exclude) ->
    Procs = erlang:processes(),
    {MaxQueue, Busiest} = lists:foldl(
        fun(P, Acc) when P =:= Exclude -> Acc;
           (P, {Max, _} = Acc) ->
            case erlang:process_info(P, message_queue_len) of
                {message_queue_len, N} when N > Max -> {N, P};
                _ -> Acc
            end
        end, {0, none}, Procs),
    {length(Procs), erlang:memory(total), MaxQueue, erlang:statistics(run_queue),
     describe(Busiest)}.

%% What the busiest process is: its registered name, or the function it
%% started in and the one it is in now.
describe(none) -> <<"-">>;
describe(Pid) ->
    Info = erlang:process_info(Pid, [registered_name, initial_call,
                                     current_stacktrace, dictionary]),
    case Info of
        undefined -> <<"(gone)">>;
        _ ->
            Name = case proplists:get_value(registered_name, Info) of
                [] -> "";
                N -> atom_to_list(N) ++ " "
            end,
            Dict = proplists:get_value(dictionary, Info, []),
            Initial = case proplists:get_value('$initial_call', Dict) of
                undefined -> proplists:get_value(initial_call, Info);
                I -> I
            end,
            %% The frames that say whose actor this is, past the receive.
            Stack = [{M, F} || {M, F, _, _} <- proplists:get_value(current_stacktrace, Info, []),
                               lists:prefix("supernova", atom_to_list(M))],
            unicode:characters_to_binary(io_lib:format("~s~p at ~p", [Name, Initial, lists:sublist(Stack, 4)]))
    end.

now_ms() -> erlang:system_time(millisecond).

mono_ms() -> erlang:monotonic_time(millisecond).

%% 1..N
rand_int(N) when N > 0 -> rand:uniform(N).

halt(Code) -> erlang:halt(Code).

%% Total size of the regular files under Dir, in bytes.
dir_bytes(Dir) ->
    filelib:fold_files(binary_to_list(Dir), ".*", true,
        fun(F, Acc) -> Acc + filelib:file_size(F) end, 0).

%% The default httpc profile keeps 2 sessions per host: with many workers the
%% queue would be in the client, and the test would measure httpc. Each
%% request gets its own connection instead.
open_client(Workers) ->
    application:ensure_all_started(inets),
    ok = httpc:set_options([{max_sessions, Workers * 2},
                            {max_keep_alive_length, 0},
                            {max_pipeline_length, 0}]),
    nil.
