-module(supernova_self_ffi).
-export([has_ascii_letter/1, sha256_hex/1, try_lock_file/1, remove_lock_file/1, list_agent_dirs/1, with_lock/2]).

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
    global:trans({supernova_self_lock, Key}, Fun).
