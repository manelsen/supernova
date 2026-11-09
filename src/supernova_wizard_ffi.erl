-module(supernova_wizard_ffi).
-export([
    read_line/1,
    write_file/2,
    set_test_inputs/1,
    set_test_write_error/1,
    get_test_writes/0,
    clear_test_state/0
]).

-define(TEST_INPUTS_KEY, {?MODULE, test_inputs}).
-define(TEST_WRITES_KEY, {?MODULE, test_writes}).
-define(TEST_WRITE_ERROR_KEY, {?MODULE, test_write_error}).

%% Prints prompt (without newline) and reads a line from stdin.
%% Returns {ok, Line} with trailing newline/CR stripped,
%% or {error, nil} on EOF or error.
read_line(Prompt) ->
    case persistent_term:get(?TEST_INPUTS_KEY, undefined) of
        undefined ->
            read_line_from_stdio(Prompt);
        [] ->
            {error, nil};
        [Line | Rest] ->
            persistent_term:put(?TEST_INPUTS_KEY, Rest),
            normalize_line(Line)
    end.

read_line_from_stdio(Prompt) ->
    io:format("~ts", [Prompt]),
    case io:get_line("") of
        eof ->
            {error, nil};
        {error, _Reason} ->
            {error, nil};
        Line ->
            normalize_line(Line)
    end.

normalize_line(Line) when is_binary(Line) ->
    {ok, string:trim(Line, trailing, "\r\n")};
normalize_line(Line) when is_list(Line) ->
    {ok, string:trim(list_to_binary(Line), trailing, "\r\n")}.

normalize_error(Msg) when is_binary(Msg) ->
    Msg;
normalize_error(Msg) when is_list(Msg) ->
    list_to_binary(Msg);
normalize_error(Msg) ->
    list_to_binary(io_lib:format("~p", [Msg])).

real_write_file(Path, Content) ->
    case file:write_file(Path, Content) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, list_to_binary(atom_to_list(Reason))}
    end.

%% Writes Content (binary) to Path on the filesystem.
%% Returns {ok, nil} on success or {error, Reason} on failure.
write_file(Path, Content) ->
    case persistent_term:get(?TEST_WRITE_ERROR_KEY, undefined) of
        undefined ->
            case persistent_term:get(?TEST_WRITES_KEY, undefined) of
                undefined ->
                    real_write_file(Path, Content);
                Writes when is_list(Writes) ->
                    persistent_term:put(?TEST_WRITES_KEY, [{Path, Content} | Writes]),
                    {ok, nil}
            end;
        Msg ->
            {error, normalize_error(Msg)}
    end.

set_test_inputs(Inputs) when is_list(Inputs) ->
    persistent_term:put(?TEST_INPUTS_KEY, Inputs),
    persistent_term:put(?TEST_WRITES_KEY, []),
    persistent_term:erase(?TEST_WRITE_ERROR_KEY),
    nil.

set_test_write_error(Msg) ->
    persistent_term:put(?TEST_WRITE_ERROR_KEY, Msg),
    case persistent_term:get(?TEST_WRITES_KEY, undefined) of
        undefined -> persistent_term:put(?TEST_WRITES_KEY, []);
        _ -> ok
    end,
    nil.

get_test_writes() ->
    case persistent_term:get(?TEST_WRITES_KEY, undefined) of
        undefined ->
            [];
        Writes ->
            lists:reverse(Writes)
    end.

clear_test_state() ->
    case persistent_term:get(?TEST_INPUTS_KEY, undefined) of
        undefined ->
            ok;
        _ ->
            persistent_term:erase(?TEST_INPUTS_KEY)
    end,
    case persistent_term:get(?TEST_WRITES_KEY, undefined) of
        undefined ->
            ok;
        _ ->
            persistent_term:erase(?TEST_WRITES_KEY)
    end,
    case persistent_term:get(?TEST_WRITE_ERROR_KEY, undefined) of
        undefined ->
            ok;
        _ ->
            persistent_term:erase(?TEST_WRITE_ERROR_KEY)
    end,
    nil.
