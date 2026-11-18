-module(supernova_chat_lanes_ffi).
-export([submit/2, submit_with_limits/4, lane_count/0, drain/2, undrain/1]).

%% Per-chat ordered execution lanes.
%%
%% Inbound turns used to run inline in the channel polling loop, so one slow
%% turn held every other chat of that channel. Jobs are now submitted to a
%% lane keyed by chat: different chats run in parallel, jobs of the same chat
%% run one at a time in arrival order (session history stays consistent).
%%
%% A single manager process (registered as `supernova_chat_lanes`) owns the
%% lane table. Each lane is a worker process that exits once its queue is
%% drained; the next job for that chat starts a new worker.

-define(NAME, supernova_chat_lanes).

submit(Key, Job) ->
    submit_with_limits(Key, Job, 50, 2000).

%% Same as submit/2 with explicit limits (tests and diagnostics).
submit_with_limits(Key, Job, MaxPending, MaxLanes) ->
    Ref = make_ref(),
    Deadline = erlang:monotonic_time(millisecond) + 900,
    manager() ! {submit, Key, Job, self(), Ref, MaxPending, MaxLanes, Deadline},
    receive
        {Ref, Accepted} -> Accepted
    after 1000 -> false
    end.

%% Number of live lanes (for tests and diagnostics).
lane_count() ->
    Ref = make_ref(),
    manager() ! {count, self(), Ref},
    receive
        {Ref, N} -> N
    after 1000 -> -1
    end.

%% Stop accepting jobs whose key starts with Prefix and wait for pending
%% jobs to finish. Returns the number of pending jobs still alive at the
%% deadline.
drain(<<>>, _TimeoutMs) ->
    -1;
drain(_Prefix, TimeoutMs) when is_integer(TimeoutMs), TimeoutMs < 0 ->
    -1;
drain(Prefix, TimeoutMs) ->
    Ref = make_ref(),
    manager() ! {drain, Prefix, self(), Ref, TimeoutMs},
    receive
        {Ref, Remaining} -> Remaining
    after TimeoutMs + 1000 -> -1
    end.

%% Reopen a prefix closed by drain (tests and registry restarts).
undrain(Prefix) ->
    manager() ! {undrain, Prefix},
    ok.

manager() ->
    case whereis(?NAME) of
        undefined ->
            Pid = spawn(fun init/0),
            try register(?NAME, Pid) of
                true -> Pid
            catch
                error:badarg ->
                    %% Another process registered first: use that one.
                    exit(Pid, kill),
                    manager()
            end;
        Pid ->
            Pid
    end.

init() ->
    process_flag(trap_exit, true),
    loop(#{}, [], []).

loop(Lanes, Draining, Waits) ->
    receive
        {submit, Key, Job, From, Ref, MaxPending, MaxLanes, Deadline} ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    From ! {Ref, false},
                    loop(Lanes, Draining, Waits);
                false ->
                    case is_draining(Key, Draining) of
                        true ->
                            From ! {Ref, false},
                            loop(Lanes, Draining, Waits);
                        false ->
                            case accept(Key, Job, Lanes, MaxPending, MaxLanes) of
                                {ok, NewLanes} ->
                                    From ! {Ref, true},
                                    loop(NewLanes, Draining, Waits);
                                {reject, Reason} ->
                                    From ! {Ref, false},
                                    log_rejection(Key, Reason),
                                    loop(Lanes, Draining, Waits)
                            end
                    end
            end;
        {drain, Prefix, From, Ref, TimeoutMs} ->
            case pending_for_prefix(Prefix, Lanes) of
                0 ->
                    From ! {Ref, 0},
                    loop(Lanes, [Prefix | Draining], Waits);
                _ ->
                    Timer = erlang:send_after(
                        TimeoutMs, self(), {drain_timeout, Prefix, From, Ref}),
                    Waits1 = [{Prefix, From, Ref, Timer} | Waits],
                    loop(Lanes, [Prefix | Draining], Waits1)
            end;
        {undrain, Prefix} ->
            loop(Lanes, lists:delete(Prefix, Draining), Waits);
        {drain_timeout, Prefix, From, Ref} ->
            From ! {Ref, pending_for_prefix(Prefix, Lanes)},
            loop(Lanes, Draining,
                 [W || {P, _, _, _} = W <- Waits, P =/= Prefix]);
        {done, Key, Worker} ->
            case maps:find(Key, Lanes) of
                {ok, {Worker, 1}} ->
                    Worker ! stop,
                    Lanes1 = maps:remove(Key, Lanes),
                    loop(Lanes1, Draining, notify_drains(Draining, Waits, Lanes1));
                {ok, {Worker, Pending}} ->
                    loop(Lanes#{Key => {Worker, Pending - 1}}, Draining, Waits);
                _ ->
                    loop(Lanes, Draining, Waits)
            end;
        {count, From, Ref} ->
            From ! {Ref, maps:size(Lanes)},
            loop(Lanes, Draining, Waits);
        {'EXIT', Pid, _Reason} ->
            %% A worker was killed: drop its lane so the next job starts fresh.
            Lanes1 = maps:filter(fun(_, {W, _}) -> W =/= Pid end, Lanes),
            loop(Lanes1, Draining, notify_drains(Draining, Waits, Lanes1));
        _ ->
            loop(Lanes, Draining, Waits)
    end.

log_rejection(Key, Reason) ->
    Now = erlang:monotonic_time(millisecond),
    Last = get({lane_rejection_log, Key}),
    case Last =:= undefined orelse Now - Last >= 10000 of
        true ->
            put({lane_rejection_log, Key}, Now),
            spawn(fun() ->
                io:format(standard_error,
                          "warn: chat lane rejected submission key=~ts reason=~p~n",
                          [Key, Reason])
            end);
        false ->
            ok
    end.

is_draining(Key, Draining) ->
    lists:any(fun(Prefix) -> starts_with(Key, Prefix) end, Draining).

starts_with(Bin, Prefix) ->
    case binary:match(Bin, Prefix) of
        {0, _} -> true;
        _ -> false
    end.

pending_for_prefix(Prefix, Lanes) ->
    maps:fold(fun(Key, {_Worker, Pending}, Acc) ->
        case starts_with(Key, Prefix) of
            true -> Acc + Pending;
            false -> Acc
        end
    end, 0, Lanes).

notify_drains(_Draining, Waits, Lanes) ->
    lists:flatmap(fun({Prefix, From, Ref, Timer} = Wait) ->
        case pending_for_prefix(Prefix, Lanes) of
            0 ->
                erlang:cancel_timer(Timer),
                From ! {Ref, 0},
                [];
            _ -> [Wait]
        end
    end, Waits).

accept(Key, Job, Lanes, MaxPending, MaxLanes) ->
    case maps:find(Key, Lanes) of
        {ok, {_Worker, Pending}} when Pending >= MaxPending ->
            {reject, pending_limit};
        {ok, {Worker, Pending}} ->
            Worker ! {job, Job},
            {ok, Lanes#{Key => {Worker, Pending + 1}}};
        error when map_size(Lanes) >= MaxLanes ->
            {reject, lane_limit};
        error ->
            Self = self(),
            Worker = spawn_link(fun() -> worker(Self, Key) end),
            Worker ! {job, Job},
            {ok, Lanes#{Key => {Worker, 1}}}
    end.

worker(Manager, Key) ->
    receive
        {job, Job} ->
            try
                Job()
            catch
                Class:Reason ->
                    io:format(standard_error,
                              "error: chat lane job failed key=~ts ~p:~p~n",
                              [Key, Class, Reason])
            end,
            Manager ! {done, Key, self()},
            worker(Manager, Key);
        stop ->
            ok
    end.
