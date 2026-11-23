-module(supernova_file_system_ffi).
-export([read_file/1, write_file/2, list_dir/1, ensure_dir/1, append_file/2,
         delete_file/1, file_exists/1, find_files/2, plain_argv/0]).

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
  case supernova_rawfs:list_dir(Path) of
    {ok, Files} -> {ok, [unicode:characters_to_binary(F) || F <- Files]};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

ensure_dir(Path) ->
  case supernova_rawfs:ensure_dir(Path) of
    ok -> {ok, nil};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

append_file(Path, Content) ->
  case file:write_file(Path, Content, [append]) of
    ok -> {ok, nil};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

delete_file(Path) ->
  case supernova_rawfs:delete(Path) of
    ok -> {ok, nil};
    {error, enoent} -> {ok, nil};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

file_exists(Path) ->
  {ok, supernova_rawfs:exists(Path)}.

find_files(Directory0, Pattern0) ->
    Directory = to_list(Directory0),
    Pattern = to_list(Pattern0),
    case supernova_rawfs:is_dir(Directory) of
        true -> [list_to_binary(Path) || Path <- filelib:wildcard(filename:join(Directory, Pattern))];
        false -> []
    end.

to_list(Value) when is_binary(Value) -> binary_to_list(Value);
to_list(Value) when is_list(Value) -> Value.

plain_argv() ->
    [list_to_binary(Arg) || Arg <- init:get_plain_arguments()].
