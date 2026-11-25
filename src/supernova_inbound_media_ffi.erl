%% Temporary files of inbound media (PRD-C, C-05).
-module(supernova_inbound_media_ffi).
-export([write/2, read/1, delete/1, sweep/2, random_id/0, download/2, file_size/1, read_head/1]).

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

%% Stream a URL straight to a file (media can be large). Plain GET; the
%% URL comes from the channel's own bridge.
download(Url, Path) ->
    ok = filelib:ensure_dir(Path),
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    case httpc:request(get, {binary_to_list(Url), []},
                       [{timeout, 600000}, {connect_timeout, 10000}, {autoredirect, false}],
                       [{stream, binary_to_list(Path)}]) of
        {ok, saved_to_file} -> {ok, nil};
        {ok, {{_, Status, _}, _, _}} ->
            _ = file:delete(Path),
            {error, iolist_to_binary(["status ", integer_to_list(Status)])};
        {error, Reason} ->
            _ = file:delete(Path),
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        _ -> 0
    end.

%% The first 64 bytes, enough to tell the type.
read_head(Path) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Fd} ->
            Result = file:read(Fd, 64),
            _ = file:close(Fd),
            case Result of
                {ok, Bytes} -> {ok, Bytes};
                _ -> {error, nil}
            end;
        _ -> {error, nil}
    end.
