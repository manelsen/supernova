-module(supernova_signal_ffi).
-behaviour(gen_event).
-export([wait_for_shutdown/0, wait_for_shutdown/2, notify_sigterm/0,
         restore_default/0]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2,
         code_change/3]).

%% Block until Supernova must stop: SIGTERM (what `docker stop` sends), or
%% the exit of a linked process.
%%
%% By default the BEAM answers SIGTERM with init:stop(), which kills every
%% process without running Supernova's own shutdown (draining the chat
%% lanes). This swaps the default signal handler for one that sends
%% SIGTERM to the waiting process instead, so `shutdown/1` runs first; the
%% VM stops when `main` returns.
wait_for_shutdown() ->
    _ = wait_for_shutdown(infinity, fun() -> nil end),
    nil.

%% For tests: a timeout in milliseconds, and a function called once the
%% handler is installed. Returns `timeout` when nothing arrived, `sigterm`
%% or `exit` otherwise.
wait_for_shutdown(Timeout, Installed) ->
    process_flag(trap_exit, true),
    install(self()),
    Installed(),
    receive
        supernova_sigterm -> sigterm;
        {'EXIT', _, _} -> exit
    after Timeout -> timeout
    end.

install(Pid) ->
    case lists:member(?MODULE, gen_event:which_handlers(erl_signal_server)) of
        true ->
            gen_event:call(erl_signal_server, ?MODULE, {set_pid, Pid});
        false ->
            ok = gen_event:swap_handler(erl_signal_server,
                                        {erl_signal_handler, []},
                                        {?MODULE, Pid})
    end.

%% What the signal server does on SIGTERM; tests use it instead of a real
%% signal.
notify_sigterm() ->
    gen_event:notify(erl_signal_server, sigterm),
    nil.

%% Give SIGTERM back to the BEAM's default handler (tests).
restore_default() ->
    case lists:member(?MODULE, gen_event:which_handlers(erl_signal_server)) of
        true ->
            gen_event:swap_handler(erl_signal_server, {?MODULE, restore},
                                   {erl_signal_handler, []});
        false -> ok
    end,
    nil.

init({Pid, _SwappedOut}) -> {ok, Pid};
init(Pid) -> {ok, Pid}.

handle_event(sigterm, Pid) ->
    Pid ! supernova_sigterm,
    {ok, Pid};
%% Every other signal keeps what the BEAM's default handler does with it
%% (SIGUSR1 writes a crash dump, SIGQUIT halts). Its state is an empty
%% record, so calling it with a placeholder is enough.
handle_event(Signal, Pid) ->
    _ = erl_signal_handler:handle_event(Signal, undefined),
    {ok, Pid}.

handle_call({set_pid, Pid}, _Old) -> {ok, ok, Pid};
handle_call(_Request, Pid) -> {ok, ok, Pid}.

handle_info(_Info, Pid) -> {ok, Pid}.
terminate(restore, _Pid) -> [];
terminate(_Reason, _Pid) -> ok.
code_change(_OldVsn, Pid, _Extra) -> {ok, Pid}.
