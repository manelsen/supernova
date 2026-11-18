-module(supernova_file_system_ffi).
-export([read_file/1, write_file/2, list_dir/1, ensure_dir/1, append_file/2,
         delete_file/1, file_exists/1]).

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

ensure_dir(Path) ->
  case filelib:ensure_dir(filename:join(Path, "__placeholder__")) of
    ok -> {ok, nil};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

append_file(Path, Content) ->
  case file:write_file(Path, Content, [append]) of
    ok -> {ok, nil};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

delete_file(Path) ->
  case file:delete(Path) of
    ok -> {ok, nil};
    {error, enoent} -> {ok, nil};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

file_exists(Path) ->
  {ok, filelib:is_file(Path) orelse filelib:is_dir(Path)}.
