%% Animated sticker frames (PRD-A, A-10): runs priv/media/sticker_frames.py
%% (Pillow), which composes each frame whole and keeps up to Max, evenly
%% spaced, as PNG.
-module(supernova_sticker_ffi).
-export([frames/3]).

frames(Path, OutDir, Max) ->
    Python = case os:getenv("SUPERNOVA_PYTHON") of
        false -> os:find_executable("python3");
        Value -> Value
    end,
    Script = filename:absname("priv/media/sticker_frames.py"),
    case Python of
        false -> {error, <<"python3 is not installed">>};
        _ ->
            Port = erlang:open_port({spawn_executable, Python},
                                    [{args, [Script, Path, OutDir, integer_to_list(Max)]},
                                     exit_status, binary, stderr_to_stdout, use_stdio]),
            collect(Port, <<>>)
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> parse(Acc);
        {Port, {exit_status, _}} -> parse_error(Acc)
    after 60000 ->
        catch erlang:port_close(Port),
        {error, <<"splitting the sticker took too long">>}
    end.

parse(Output) ->
    try json:decode(Output) of
        #{<<"frames">> := Frames} when Frames =/= [] -> {ok, Frames};
        _ -> {error, <<"the sticker had no frames">>}
    catch _:_ -> {error, <<"could not split the sticker">>}
    end.

parse_error(Output) ->
    try json:decode(Output) of
        #{<<"error">> := Message} -> {error, Message};
        _ -> {error, <<"could not split the sticker">>}
    catch _:_ -> {error, <<"could not split the sticker">>}
    end.
