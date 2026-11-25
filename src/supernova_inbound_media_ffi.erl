%% Temporary files of inbound media (PRD-C, C-05).
-module(supernova_inbound_media_ffi).
-export([write/2, read/1, delete/1, sweep/2, random_id/0]).

write(Path, Bytes) ->
    ok = filelib:ensure_dir(Path),
    case file:write_file(Path, Bytes) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

read(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _} -> {error, nil}
    end.

delete(Path) ->
    _ = file:delete(Path),
    nil.

%% Delete files in Dir last modified more than MaxAgeMs ago; returns how many.
sweep(Dir, MaxAgeMs) ->
    Now = erlang:system_time(second),
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foldl(fun(Name, Count) ->
                Path = filename:join(Dir, Name),
                case file:read_file_info(Path, [{time, posix}]) of
                    {ok, Info} ->
                        Age = (Now - element(6, Info)) * 1000,
                        case Age >= MaxAgeMs of
                            true -> _ = file:delete(Path), Count + 1;
                            false -> Count
                        end;
                    _ -> Count
                end
            end, 0, Names);
        {error, _} -> 0
    end.

random_id() ->
    list_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:strong_rand_bytes(16)]).
