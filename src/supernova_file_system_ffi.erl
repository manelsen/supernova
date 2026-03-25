-module(supernova_file_system_ffi).
-export([read_file/1, write_file/2, list_dir/1]).

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

list_dir(Path) ->
  case file:list_dir(Path) of
    {ok, Files} -> {ok, [list_to_binary(F) || F <- Files]};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.
