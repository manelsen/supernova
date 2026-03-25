-module(supernova_wizard_ffi).
-export([read_line/1, write_file/2]).

%% Prints prompt (without newline) and reads a line from stdin.
%% Returns {ok, Line} with trailing newline/CR stripped,
%% or {error, nil} on EOF or error.
read_line(Prompt) ->
    io:format("~ts", [Prompt]),
    case io:get_line("") of
        eof ->
            {error, nil};
        {error, _Reason} ->
            {error, nil};
        Line when is_binary(Line) ->
            {ok, string:trim(Line, trailing, "\r\n")};
        Line when is_list(Line) ->
            {ok, string:trim(list_to_binary(Line), trailing, "\r\n")}
    end.

%% Writes Content (binary) to Path on the filesystem.
%% Returns {ok, nil} on success or {error, Reason} on failure.
write_file(Path, Content) ->
    case file:write_file(Path, Content) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, list_to_binary(atom_to_list(Reason))}
    end.
