-module(supernova_mcp_ffi).
-export([
  open_port/3,
  send_and_receive/3,
  send_and_receive_classified/3,
  receive_line/2,
  receive_line_classified/2,
  send_data/2,
  close_port/1,
  monotonic_ms/0,
  dynamic_to_json/1
]).

%% Open an OS process and return {ok, Port} or {error, Reason}.
%% Uses Erlang port with {line, 1024} for line-buffered STDIO communication.
open_port(Command, Args, Env) ->
  try
    CommandStr = binary_to_list(Command),
    ArgsStrs = [binary_to_list(A) || A <- Args],
    EnvStrs = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Env],
    case resolve_command(CommandStr) of
      {ok, Executable} ->
        Port = erlang:open_port(
          {spawn_executable, Executable},
          [
            binary,
            {args, ArgsStrs},
            {env, EnvStrs},
            {line, 1048576},
            exit_status
          ]
        ),
        {ok, Port};
      {error, Reason} ->
        {error, list_to_binary(Reason)}
    end
  catch
    _:CatchReason ->
      {error, list_to_binary(io_lib:format("Failed to open port: ~p", [CatchReason]))}
  end.

%% Resolve command names from PATH when a bare executable name is provided.
resolve_command(CommandStr) ->
  case {filename:pathtype(CommandStr), lists:member($/, CommandStr)} of
    {absolute, _} ->
      {ok, CommandStr};
    {_, true} ->
      %% Relative paths with "/" are resolved from current working directory.
      {ok, filename:absname(CommandStr)};
    {_, false} ->
      case os:find_executable(CommandStr) of
        false ->
          {error, io_lib:format("Failed to open port: command not found (~s)", [CommandStr])};
        Executable ->
          {ok, Executable}
      end
  end.

%% Send data to port and wait for a complete line response.
%% Returns {ok, Line} | {error, Reason}.
%% NOTE: This must be called from the process that opened the port,
%% or the port's controlling process must be changed first.
send_and_receive(Port, Data, TimeoutMs) ->
  case send_and_receive_classified(Port, Data, TimeoutMs) of
    {ok, Line} -> {ok, Line};
    {error, {_Kind, Msg}} -> {error, Msg}
  end.

%% Typed variant classifying process exit vs timeout vs other transport failure.
send_and_receive_classified(Port, Data, TimeoutMs) ->
  try
    %% Ensure this process is the port's controlling process
    erlang:port_connect(Port, self()),
    Port ! {self(), {command, <<Data/binary, "\n">>}},
    wait_for_line_classified(Port, TimeoutMs)
  catch
    _:Reason ->
      classify_port_error(Port, "Send/receive failed", Reason)
  end.

%% Wait for the next complete line from the port without sending new data.
receive_line(Port, TimeoutMs) ->
  case receive_line_classified(Port, TimeoutMs) of
    {ok, Line} -> {ok, Line};
    {error, {_Kind, Msg}} -> {error, Msg}
  end.

receive_line_classified(Port, TimeoutMs) ->
  try
    erlang:port_connect(Port, self()),
    wait_for_line_classified(Port, TimeoutMs)
  catch
    _:Reason ->
      classify_port_error(Port, "Receive failed", Reason)
  end.

classify_port_error(Port, Label, badarg) ->
  case erlang:port_info(Port) of
    undefined -> {error, {process_dead, <<"Port closed">>}};
    _ -> {error, {other_error, list_to_binary(io_lib:format("~s: badarg", [Label]))}}
  end;
classify_port_error(_Port, Label, Reason) ->
  {error, {other_error, list_to_binary(io_lib:format("~s: ~p", [Label, Reason]))}}.

%% Current monotonic clock in milliseconds.
monotonic_ms() ->
  erlang:monotonic_time(millisecond).

%% Send data to port without waiting for response (fire-and-forget).
%% Returns {ok, nil} | {error, Reason}.
send_data(Port, Data) ->
  try
    erlang:port_connect(Port, self()),
    Port ! {self(), {command, <<Data/binary, "\n">>}},
    {ok, nil}
  catch
    _:Reason ->
      {error, list_to_binary(io_lib:format("Send failed: ~p", [Reason]))}
  end.

%% Close the port and clean up.
%% Returns nil.
close_port(Port) ->
  try
    catch port_close(Port)
  catch
    _:_ -> nil
  end,
  nil.

%% Internal: wait for a complete line from the port under an absolute monotonic deadline.
wait_for_line_classified(Port, TimeoutMs) ->
  DeadlineMs = monotonic_ms() + max(0, TimeoutMs),
  collect_line_until(Port, <<>>, DeadlineMs).

remaining_timeout(DeadlineMs) ->
  DeadlineMs - monotonic_ms().

%% Internal: collect EOL-delimited chunks into Acc until EOL or DeadlineMs expires.
collect_line_until(Port, Acc, DeadlineMs) ->
  case remaining_timeout(DeadlineMs) of
    Remaining when Remaining =< 0 ->
      {error, {timeout, <<"timeout">>}};
    Remaining ->
      receive
        {Port, {data, {eol, Rest}}} ->
          {ok, <<Acc/binary, Rest/binary>>};
        {Port, {data, {noeol, Partial}}} ->
          collect_line_until(Port, <<Acc/binary, Partial/binary>>, DeadlineMs);
        {Port, {exit_status, Status}} ->
          {error, {process_dead, list_to_binary(io_lib:format("Process exited with status ~p", [Status]))}}
      after Remaining ->
        {error, {timeout, <<"timeout">>}}
      end
  end.

%% Convert a dynamic (arbitrary Erlang term) to JSON string.
%% Uses Gleam's JSON encoding.
dynamic_to_json(Term) ->
  try
    %% Convert Erlang term to JSON string using thoas or jsone
    %% For now, just use Erlang term_to_binary and format
    %% This is a simplified version - in production, use a proper JSON library
    JsonStr = format_as_json(Term),
    {ok, list_to_binary(JsonStr)}
  catch
    _:Reason ->
      {error, list_to_binary(io_lib:format("Failed to encode JSON: ~p", [Reason]))}
  end.

%% Escape a string for safe JSON embedding (including all control chars < 0x20).
escape_json_string([]) -> [];
escape_json_string([$" | Rest])  -> [$\\, $"  | escape_json_string(Rest)];
escape_json_string([$\\ | Rest]) -> [$\\, $\\ | escape_json_string(Rest)];
escape_json_string([$\n | Rest]) -> [$\\, $n  | escape_json_string(Rest)];
escape_json_string([$\r | Rest]) -> [$\\, $r  | escape_json_string(Rest)];
escape_json_string([$\t | Rest]) -> [$\\, $t  | escape_json_string(Rest)];
escape_json_string([C | Rest]) when C >= 0, C < 32 ->
  lists:flatten(io_lib:format("\\u~4.16.0b", [C])) ++ escape_json_string(Rest);
escape_json_string([C | Rest])   -> [C        | escape_json_string(Rest)].

%% Simple JSON formatter for common Erlang terms.
format_as_json(Term) when is_binary(Term) ->
  "\"" ++ escape_json_string(binary_to_list(Term)) ++ "\"";
format_as_json(Term) when is_list(Term) ->
  case io_lib:printable_list(Term) of
    true ->
      "\"" ++ escape_json_string(Term) ++ "\"";
    false ->
      %% It's a list/array
      "[" ++ string:join([format_as_json(E) || E <- Term], ",") ++ "]"
  end;
format_as_json(Term) when is_map(Term) ->
  Pairs = maps:to_list(Term),
  FormattedPairs = [format_key_value(K, V) || {K, V} <- Pairs],
  "{" ++ string:join(FormattedPairs, ",") ++ "}";
format_as_json(Term) when is_integer(Term) ->
  integer_to_list(Term);
format_as_json(Term) when is_float(Term) ->
  float_to_list(Term);
format_as_json(true) ->
  "true";
format_as_json(false) ->
  "false";
format_as_json(nil) ->
  "null";
format_as_json(null) ->
  "null";
format_as_json(_) ->
  "null".

format_key_value(Key, Value) when is_binary(Key) ->
  "\"" ++ escape_json_string(binary_to_list(Key)) ++ "\":" ++ format_as_json(Value);
format_key_value(Key, Value) when is_atom(Key) ->
  "\"" ++ escape_json_string(atom_to_list(Key)) ++ "\":" ++ format_as_json(Value);
format_key_value(Key, Value) ->
  "\"" ++ escape_json_string(lists:flatten(io_lib:format("~p", [Key]))) ++ "\":" ++ format_as_json(Value).
