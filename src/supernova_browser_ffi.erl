-module(supernova_browser_ffi).

-export([
    open_session/2,
    click/3,
    type_text/4,
    evaluate/3,
    extract_readable/2,
    screenshot/2,
    close_session/1
]).

-define(SESSIONS_TABLE, supernova_browser_sessions).

open_session(Url, TimeoutMs) ->
    ensure_sessions_table(),
    case open_runner_port() of
        {ok, Port} ->
            Command = open_command(normalize_binary(Url), TimeoutMs),
            case send_command(Port, Command, TimeoutMs) of
                {ok, Response} ->
                    SessionId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
                    true = ets:insert(?SESSIONS_TABLE, {SessionId, Port}),
                    {ok, wrap_open_response(SessionId, Response)};
                {error, Reason} ->
                    close_port_safe(Port),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

click(SessionId, Selector, TimeoutMs) ->
    with_session(normalize_binary(SessionId), fun(Port) ->
        send_session_command(
            normalize_binary(SessionId),
            Port,
            selector_command(<<"click">>, normalize_binary(Selector), TimeoutMs),
            TimeoutMs
        )
    end).

type_text(SessionId, Selector, Text, TimeoutMs) ->
    with_session(normalize_binary(SessionId), fun(Port) ->
        send_session_command(
            normalize_binary(SessionId),
            Port,
            type_command(normalize_binary(Selector), normalize_binary(Text), TimeoutMs),
            TimeoutMs
        )
    end).

evaluate(SessionId, Script, TimeoutMs) ->
    with_session(normalize_binary(SessionId), fun(Port) ->
        send_session_command(
            normalize_binary(SessionId),
            Port,
            evaluate_command(normalize_binary(Script), TimeoutMs),
            TimeoutMs
        )
    end).

extract_readable(SessionId, TimeoutMs) ->
    with_session(normalize_binary(SessionId), fun(Port) ->
        send_session_command(
            normalize_binary(SessionId),
            Port,
            simple_command(<<"extract_readable">>, TimeoutMs),
            TimeoutMs
        )
    end).

screenshot(SessionId, TimeoutMs) ->
    with_session(normalize_binary(SessionId), fun(Port) ->
        send_session_command(
            normalize_binary(SessionId),
            Port,
            simple_command(<<"screenshot">>, TimeoutMs),
            TimeoutMs
        )
    end).

close_session(SessionId) ->
    ensure_sessions_table(),
    SessionKey = normalize_binary(SessionId),
    case ets:lookup(?SESSIONS_TABLE, SessionKey) of
        [{_, Port}] ->
            Result = send_command(Port, close_command(), 5000),
            cleanup_session(SessionKey, Port),
            Result;
        [] ->
            {error, <<"Unknown browser session: ", SessionKey/binary>>}
    end.

ensure_sessions_table() ->
    case ets:info(?SESSIONS_TABLE) of
        undefined ->
            ets:new(?SESSIONS_TABLE, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

with_session(SessionId, Fun) ->
    ensure_sessions_table(),
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [{_, Port}] ->
            Fun(Port);
        [] ->
            {error, <<"Unknown browser session: ", SessionId/binary>>}
    end.

send_session_command(SessionId, Port, Command, TimeoutMs) ->
    case send_command(Port, Command, TimeoutMs) of
        {ok, Response} ->
            {ok, Response};
        {error, Reason} ->
            cleanup_session(SessionId, Port),
            {error, Reason}
    end.

cleanup_session(SessionId, Port) ->
    catch ets:delete(?SESSIONS_TABLE, SessionId),
    close_port_safe(Port),
    ok.

open_runner_port() ->
    case resolve_node() of
        {ok, NodeExecutable} ->
            ScriptPath = filename:absname("scripts/browser_runner.mjs"),
            case filelib:is_regular(ScriptPath) of
                true ->
                    try
                        Port = erlang:open_port(
                            {spawn_executable, NodeExecutable},
                            [
                                binary,
                                use_stdio,
                                exit_status,
                                stderr_to_stdout,
                                {args, [ScriptPath]}
                            ]
                        ),
                        {ok, Port}
                    catch
                        _:Reason ->
                            {error, format_reason("Failed to start browser runner", Reason)}
                    end;
                false ->
                    {error, <<"Browser runner script not found: ", (unicode:characters_to_binary(ScriptPath))/binary>>}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

resolve_node() ->
    case os:find_executable("node") of
        false ->
            {error, <<"node executable not found">>};
        Executable ->
            {ok, Executable}
    end.

send_command(Port, Command, TimeoutMs) ->
    try
        Port ! {self(), {command, <<Command/binary, "\n">>}},
        collect_response(Port, <<>>, TimeoutMs)
    catch
        _:Reason ->
            {error, format_reason("Browser command failed", Reason)}
    end.

collect_response(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            NewAcc = <<Acc/binary, Data/binary>>,
            case split_first_line(NewAcc) of
                {line, Line} -> normalize_line(Line);
                more -> collect_response(Port, NewAcc, TimeoutMs)
            end;
        {Port, {exit_status, Status}} ->
            normalize_exit(Acc, Status)
    after TimeoutMs ->
        {error, <<"Browser command timed out">>}
    end.

split_first_line(Bin) ->
    case binary:match(Bin, <<"\n">>) of
        {Pos, _Len} ->
            {line, binary:part(Bin, 0, Pos)};
        nomatch ->
            more
    end.

normalize_line(Line) ->
    Trimmed = trim_binary(Line),
    case Trimmed of
        <<"ERROR: ", Rest/binary>> -> {error, Rest};
        _ when Trimmed =:= <<>> -> {error, <<"Browser runner returned empty response">>};
        <<"{", _/binary>> -> {ok, Trimmed};
        <<"[", _/binary>> -> {ok, Trimmed};
        <<"\"", _/binary>> -> {ok, Trimmed};
        <<"true">> -> {ok, Trimmed};
        <<"false">> -> {ok, Trimmed};
        <<"null">> -> {ok, Trimmed};
        <<Digit, _/binary>> when Digit >= $0, Digit =< $9 -> {ok, Trimmed};
        <<$-, Digit, _/binary>> when Digit >= $0, Digit =< $9 -> {ok, Trimmed};
        _ -> {error, <<"Unexpected browser runner output: ", Trimmed/binary>>}
    end.

normalize_exit(Acc, 0) ->
    case trim_binary(Acc) of
        <<>> -> {error, <<"Browser runner exited without response">>};
        Trimmed -> normalize_line(Trimmed)
    end;
normalize_exit(Acc, Status) ->
    case trim_binary(Acc) of
        <<>> ->
            {error, <<"Browser runner exited with status ", (integer_to_binary(Status))/binary>>};
        Trimmed ->
            case normalize_line(Trimmed) of
                {ok, _} ->
                    {error, <<"Browser runner exited with status ", (integer_to_binary(Status))/binary, ": ", Trimmed/binary>>};
                Error ->
                    Error
            end
    end.

close_port_safe(Port) ->
    catch port_close(Port),
    ok.

wrap_open_response(SessionId, <<"{", Rest/binary>>) ->
    <<"{\"session_id\":\"", SessionId/binary, "\",", Rest/binary>>;
wrap_open_response(SessionId, _Other) ->
    <<"{\"session_id\":\"", SessionId/binary, "\"}">>.

open_command(Url, TimeoutMs) ->
    <<"{\"op\":\"open\",\"url\":\"", (escape_json(Url))/binary, "\",\"timeout_ms\":", (integer_to_binary(TimeoutMs))/binary, "}">>.

selector_command(Op, Selector, TimeoutMs) ->
    <<"{\"op\":\"", Op/binary, "\",\"selector\":\"", (escape_json(Selector))/binary, "\",\"timeout_ms\":", (integer_to_binary(TimeoutMs))/binary, "}">>.

type_command(Selector, Text, TimeoutMs) ->
    <<"{\"op\":\"type\",\"selector\":\"", (escape_json(Selector))/binary, "\",\"text\":\"", (escape_json(Text))/binary, "\",\"timeout_ms\":", (integer_to_binary(TimeoutMs))/binary, "}">>.

evaluate_command(Script, TimeoutMs) ->
    <<"{\"op\":\"evaluate\",\"script\":\"", (escape_json(Script))/binary, "\",\"timeout_ms\":", (integer_to_binary(TimeoutMs))/binary, "}">>.

simple_command(Op, TimeoutMs) ->
    <<"{\"op\":\"", Op/binary, "\",\"timeout_ms\":", (integer_to_binary(TimeoutMs))/binary, "}">>.

close_command() ->
    <<"{\"op\":\"close\"}">>.

escape_json(Value) ->
    EscapedBackslashes = binary:replace(Value, <<"\\">>, <<"\\\\">>, [global]),
    EscapedQuotes = binary:replace(EscapedBackslashes, <<"\"">>, <<"\\\"">>, [global]),
    EscapedNewlines = binary:replace(EscapedQuotes, <<"\n">>, <<"\\n">>, [global]),
    EscapedReturns = binary:replace(EscapedNewlines, <<"\r">>, <<"\\r">>, [global]),
    binary:replace(EscapedReturns, <<"\t">>, <<"\\t">>, [global]).

trim_binary(Value) when is_binary(Value) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Value)));
trim_binary(Value) ->
    trim_binary(normalize_binary(Value)).

normalize_binary(Value) when is_binary(Value) ->
    Value;
normalize_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
normalize_binary(Value) when is_integer(Value) ->
    integer_to_binary(Value);
normalize_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

format_reason(Prefix, Reason) ->
    <<(unicode:characters_to_binary(Prefix))/binary, ": ", (normalize_binary(io_lib:format("~p", [Reason])))/binary>>.
