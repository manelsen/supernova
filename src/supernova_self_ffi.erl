-module(supernova_self_ffi).
-export([has_ascii_letter/1, sha256_hex/1, try_lock_file/1, remove_lock_file/1, list_agent_dirs/1, with_lock/2,
         clear_dir/1, try_global_lock/1, release_global_lock/1, rename_file/2]).

has_ascii_letter(Binary) when is_binary(Binary) ->
    lists:any(fun(C) ->
        (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
    end, binary_to_list(Binary)).

sha256_hex(Value) when is_binary(Value) ->
    Hash = crypto:hash(sha256, Value),
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Hash]).

try_lock_file(Path) when is_binary(Path) ->
    ok = filelib:ensure_dir(Path),
    case file:open(Path, [write, exclusive]) of
        {ok, Handle} ->
            ok = file:close(Handle),
            true;
        {error, eexist} ->
            false;
        {error, _} ->
            false
    end.

remove_lock_file(Path) when is_binary(Path) ->
    _ = file:delete(Path),
    nil.

list_agent_dirs(Path) when is_binary(Path) ->
    case file:list_dir(Path) of
        {ok, Names} -> lists:sort([list_to_binary(Name) || Name <- Names, filelib:is_dir(filename:join(Path, Name))]);
        {error, _} -> []
    end.

with_lock(Key, Fun) when is_function(Fun, 0) ->
    global:trans({{supernova_self_lock, Key}, self()}, Fun).

%% Remove everything inside Dir but keep Dir. Returns the number of regular
%% files removed. A missing directory counts as empty.
%% The path stays a binary: binary_to_list would split UTF-8 bytes into
%% separate characters and point at a different directory.
clear_dir(Dir) when is_binary(Dir) ->
    case file:list_dir(Dir) of
        {error, enoent} -> {ok, 0};
        {error, Reason} -> {error, list_to_binary(file:format_error(Reason))};
        {ok, Names} ->
            Count = filelib:fold_files(Dir, ".*", true, fun(_, N) -> N + 1 end, 0),
            Results = [file:del_dir_r(filename:join(Dir, Name)) || Name <- Names],
            case [R || R <- Results, R =/= ok] of
                [] -> {ok, Count};
                [{error, Reason} | _] -> {error, list_to_binary(file:format_error(Reason))}
            end
    end.

%% Non-blocking lock owned by the calling process. The global name server
%% releases it automatically when the owner dies, so a crash cannot leave a
%% stale lock behind.
try_global_lock(Key) ->
    global:set_lock({{supernova_reflection, Key}, self()}, [node()], 0).

release_global_lock(Key) ->
    _ = global:del_lock({{supernova_reflection, Key}, self()}, [node()]),
    nil.

rename_file(From, To) ->
    case file:rename(From, To) of
        ok -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
    end.
