-module(supernova_safe_shell_ffi).
-export([run_command/1]).

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
        collect_output(Port, <<>>)
      catch
        _:Reason ->
          {error, <<"Command failed: ", (list_to_binary(io_lib:format("~p", [Reason])))/binary>>}
      end
  end.

collect_output(Port, Acc) ->
  receive
    {Port, {data, Data}} ->
      collect_output(Port, <<Acc/binary, Data/binary>>);
    {Port, {exit_status, 0}} ->
      {ok, string:trim(Acc, trailing, "\n")};
    {Port, {exit_status, Status}} ->
      {error, <<"Exit status ", (integer_to_binary(Status))/binary, ": ", Acc/binary>>}
  after 10000 ->
    port_close(Port),
    {error, <<"Command timed out">>}
  end.
