-module(supernova_safe_shell_ffi).
-export([run_command/1]).

%% Run a shell command and return the output.
run_command(Command) ->
  try
    Port = open_port({spawn, Command}, [exit_status, stderr_to_stdout, binary]),
    collect_output(Port, <<>>)
  catch
    _:Reason ->
      {error, <<"Command failed: ", (list_to_binary(io_lib:format("~p", [Reason])))/binary>>}
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
