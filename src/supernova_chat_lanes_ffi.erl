-module(supernova_chat_lanes_ffi).
-export([submit/2, lane_count/0]).

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
    manager() ! {submit, Key, Job},
    nil.

%% Number of live lanes (for tests and diagnostics).
lane_count() ->
    Ref = make_ref(),
    manager() ! {count, self(), Ref},
    receive
        {Ref, N} -> N
    after 1000 -> -1
    end.

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
    loop(#{}).

loop(Lanes) ->
    receive
        {submit, Key, Job} ->
            case maps:find(Key, Lanes) of
                {ok, {Worker, Pending}} ->
                    Worker ! {job, Job},
                    loop(Lanes#{Key => {Worker, Pending + 1}});
                error ->
                    Self = self(),
                    Worker = spawn_link(fun() -> worker(Self, Key) end),
                    Worker ! {job, Job},
                    loop(Lanes#{Key => {Worker, 1}})
            end;
        {done, Key, Worker} ->
            case maps:find(Key, Lanes) of
                {ok, {Worker, 1}} ->
                    Worker ! stop,
                    loop(maps:remove(Key, Lanes));
                {ok, {Worker, Pending}} ->
                    loop(Lanes#{Key => {Worker, Pending - 1}});
                _ ->
                    loop(Lanes)
            end;
        {count, From, Ref} ->
            From ! {Ref, maps:size(Lanes)},
            loop(Lanes);
        {'EXIT', Pid, _Reason} ->
            %% A worker was killed: drop its lane so the next job starts fresh.
            loop(maps:filter(fun(_, {W, _}) -> W =/= Pid end, Lanes));
        _ ->
            loop(Lanes)
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
