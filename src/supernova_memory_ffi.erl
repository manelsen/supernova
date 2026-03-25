-module(supernova_memory_ffi).
-export([read_file/1, write_file/2, current_timestamp/0]).

read_file(Path) ->
  case file:read_file(Path) of
    {ok, Binary} -> {ok, Binary};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

write_file(Path, Content) ->
  case file:write_file(Path, Content) of
    ok -> {ok, nil};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

current_timestamp() ->
  erlang:system_time(millisecond).
