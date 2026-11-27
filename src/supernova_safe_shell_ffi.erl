-module(supernova_safe_shell_ffi).
-export([run_command/1]).

-define(MAX_BYTES, 65536).
-define(TIMEOUT_MS, 10000).

%% Run an argv list directly, never through a shell.
%%
%% `open_port({spawn, Command})` hands the string to /bin/sh, so any shell
%% operator the validator missed would run. `spawn_executable` with `args`
%% passes each item as a literal argument.
run_command([]) ->
  {error, <<"Empty command">>};
run_command([Cmd | Args]) ->
  case os:find_executable(unicode:characters_to_list(Cmd)) of
    false ->
      {error, <<"Command not found: ", Cmd/binary>>};
    Path ->
      try
        Port = open_port({spawn_executable, Path},
                         [{args, Args}, exit_status, stderr_to_stdout, binary,
                          use_stdio, hide]),
        Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT_MS,
        collect_output(Port, <<>>, Deadline)
      catch
        _:Reason ->
          {error, <<"Command failed: ", (list_to_binary(io_lib:format("~p", [Reason])))/binary>>}
      end
  end.

%% The output is kept up to ?MAX_BYTES and the rest is drained and dropped
%% (Qwen 4, B5): a `cat` of a big file must not grow the BEAM's memory. The
%% time limit counts from the start, not from the last chunk, so a command
%% that trickles output still stops.
collect_output(Port, Acc, Deadline) ->
  Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
  receive
    {Port, {data, Data}} ->
      collect_output(Port, keep(Acc, Data), Deadline);
    {Port, {exit_status, 0}} ->
      {ok, string:trim(mark_cut(Acc), trailing, "\n")};
    {Port, {exit_status, Status}} ->
      {error, <<"Exit status ", (integer_to_binary(Status))/binary, ": ", (mark_cut(Acc))/binary>>}
  after Left ->
    catch port_close(Port),
    {error, <<"Command timed out">>}
  end.

keep(Acc, _Data) when byte_size(Acc) > ?MAX_BYTES -> Acc;
keep(Acc, Data) ->
  Room = ?MAX_BYTES - byte_size(Acc),
  case Data of
    <<Kept:Room/binary, _/binary>> -> <<Acc/binary, Kept/binary, "!">>;
    _ -> <<Acc/binary, Data/binary>>
  end.

%% One byte past the limit marks a cut output.
mark_cut(Acc) when byte_size(Acc) > ?MAX_BYTES ->
  <<Kept:?MAX_BYTES/binary, _/binary>> = Acc,
  <<Kept/binary, "\n[output cut at 64 KiB]">>;
mark_cut(Acc) -> Acc.
