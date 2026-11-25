-module(supernova_file_system_ffi).
-export([read_file/1, write_file/2, write_file_atomic/2, list_dir/1, ensure_dir/1, append_file/2,
         delete_file/1, file_exists/1, find_files/2, plain_argv/0]).

%% Every call here is raw: it runs in the caller's process, with no
%% file_server round trip and no io server process (PRD-P, P-06). Under load
%% the file_server is one process for the whole VM.
read_file(Path) ->
  case file:read_file(Path, [raw]) of
    {ok, Binary} -> {ok, Binary};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

write_file(Path, Content) ->
  case file:write_file(Path, Content, [raw]) of
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

%% Write to a temporary file next to Path, then rename over it: a reader sees
%% the old content or the new, never a truncated file. The temporary name is
%% unique, so two writers never share it.
write_file_atomic(Path, Content) ->
  Tmp = iolist_to_binary([Path, ".tmp-",
                          integer_to_list(erlang:unique_integer([positive]))]),
  case file:write_file(Tmp, Content, [raw]) of
    ok ->
      case supernova_rawfs:rename(Tmp, Path) of
        ok -> {ok, nil};
        {error, Reason} ->
          _ = supernova_rawfs:delete(Tmp),
          {error, list_to_binary(file:format_error(Reason))}
      end;
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.

append_file(Path, Content) ->
  case file:write_file(Path, Content, [append, raw]) of
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
