-module(supernova_rawfs).
%% File operations that go straight to the disk. file:list_dir, make_dir,
%% rename, delete, read_file_info and everything in filelib pass through
%% file_server_2, one process for the whole VM: under load every chat
%% queued there to append a message or check a directory. prim_file and the
%% raw option skip it.
-export([exists/1, is_dir/1, is_file/1, ensure_dir/1, list_dir/1, delete/1,
         rename/2, file_size/1]).

-include_lib("kernel/include/file.hrl").

info(Path) -> file:read_file_info(Path, [raw]).

exists(Path) ->
    case info(Path) of
        {ok, _} -> true;
        _ -> false
    end.

is_dir(Path) ->
    case info(Path) of
        {ok, #file_info{type = directory}} -> true;
        _ -> false
    end.

is_file(Path) ->
    case info(Path) of
        {ok, #file_info{type = regular}} -> true;
        _ -> false
    end.

file_size(Path) ->
    case info(Path) of
        {ok, #file_info{size = Size}} -> Size;
        _ -> 0
    end.

%% The directory and its parents.
ensure_dir(Dir0) ->
    Dir = filename:absname(Dir0),
    case is_dir(Dir) of
        true -> ok;
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true -> ok;
                false ->
                    case ensure_dir(Parent) of
                        ok ->
                            case prim_file:make_dir(Dir) of
                                ok -> ok;
                                %% Made meanwhile by someone else is fine;
                                %% a file in the way is not.
                                {error, eexist} ->
                                    case is_dir(Dir) of
                                        true -> ok;
                                        false -> {error, enotdir}
                                    end;
                                Error -> Error
                            end;
                        Error -> Error
                    end
            end
    end.

list_dir(Path) -> prim_file:list_dir(Path).

delete(Path) -> prim_file:delete(Path).

rename(From, To) -> prim_file:rename(From, To).
