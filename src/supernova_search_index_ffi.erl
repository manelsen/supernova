-module(supernova_search_index_ffi).
-export([complete_lines/2, checksum/2, parse_entries/1]).

%% The complete lines of `Bytes` from byte `From` on, each with its offset:
%% a line still being written (no newline yet) is left for later. Returns
%% the lines and the offset just past the last newline.
complete_lines(Bytes, From) when From >= byte_size(Bytes) ->
    {[], From};
complete_lines(Bytes, From) ->
    Size = byte_size(Bytes),
    case binary:matches(Bytes, <<"\n">>, [{scope, {From, Size - From}}]) of
        [] ->
            {[], From};
        Newlines ->
            {Lines, End} =
                lists:foldl(
                    fun({At, 1}, {Acc, Start}) ->
                        {[{Start, binary:part(Bytes, Start, At - Start)} | Acc], At + 1}
                    end,
                    {[], From},
                    Newlines
                ),
            {lists:reverse(Lines), End}
    end.

%% A checksum of the first `Upto` bytes: a file rewritten in place (not
%% only appended to) no longer matches its index.
checksum(Bytes, Upto) when Upto =< byte_size(Bytes) ->
    erlang:crc32(binary:part(Bytes, 0, Upto));
checksum(_Bytes, _Upto) ->
    -1.

%% The entries of an index file's body ("offset\tlength\tfolded" lines), as
%% `search_index.Entry` records, or an error when a line is not one.
parse_entries(Body) ->
    try
        Lines = binary:split(Body, <<"\n">>, [global, trim_all]),
        {ok, [parse_entry(Line) || Line <- Lines]}
    catch
        _:_ -> {error, nil}
    end.

parse_entry(Line) ->
    [Offset, Rest] = binary:split(Line, <<"\t">>),
    [Length, Folded] = binary:split(Rest, <<"\t">>),
    {entry, binary_to_integer(Offset), binary_to_integer(Length), Folded}.
