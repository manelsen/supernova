-module(supernova_tail_ffi).
-export([read_tail_lines/2]).

-define(CHUNK, 65536).

%% The last N non-empty lines of a file, oldest first, reading backwards in
%% chunks: a conversation window costs the same for a file of a hundred
%% lines or of a million. A missing file has no lines.
read_tail_lines(Path, N) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                {ok, Size} = file:position(Fd, eof),
                {ok, tail(Fd, Size, N, <<>>)}
            catch
                Class:Reason ->
                    {error, unicode:characters_to_binary(
                              io_lib:format("~p:~p", [Class, Reason]))}
            after
                file:close(Fd)
            end;
        {error, enoent} -> {ok, []};
        {error, Reason} ->
            {error, unicode:characters_to_binary(file:format_error(Reason))}
    end.

tail(Fd, Pos, N, Acc) ->
    Lines = [L || L <- binary:split(Acc, <<"\n">>, [global]), L =/= <<>>],
    %% Before the start of the file, the first line may be cut: it only
    %% counts once more than N lines are in hand.
    case Pos =:= 0 orelse length(Lines) > N of
        true ->
            Whole = case Pos of
                0 -> Lines;
                _ -> tl(Lines)
            end,
            lists:nthtail(max(length(Whole) - N, 0), Whole);
        false ->
            Read = min(?CHUNK, Pos),
            Start = Pos - Read,
            {ok, Chunk} = file:pread(Fd, Start, Read),
            tail(Fd, Start, N, <<Chunk/binary, Acc/binary>>)
    end.
