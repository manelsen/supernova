-module(isolation_test_ffi).
-export([gleam_files_under/1, read_file/1]).

%% Returns every .gleam file below Dir as a UTF-8 binary path.
gleam_files_under(DirBin) ->
  Dir = binary_to_list(DirBin),
  [unicode:characters_to_binary(Path) || Path <- walk(Dir)].

walk(Dir) ->
  case file:list_dir(Dir) of
    {ok, Entries} ->
      lists:flatmap(
        fun(Entry) ->
          Path = filename:join(Dir, Entry),
          case filelib:is_dir(Path) of
            true -> walk(Path);
            false ->
              case filename:extension(Path) of
                ".gleam" -> [Path];
                _ -> []
              end
          end
        end,
        Entries
      );
    {error, _} ->
      []
  end.

read_file(PathBin) ->
  {ok, Contents} = file:read_file(binary_to_list(PathBin)),
  Contents.
