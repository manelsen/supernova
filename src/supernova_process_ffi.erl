-module(supernova_process_ffi).
-export([kill_process/1, list_processes/0, process_info/1, spawn_background/2]).

list_processes() ->
    case run_command("ps -eo pid=,pcpu=,pmem=,args=") of
        {ok, Output} ->
            {ok, normalize_process_lines(Output)};
        Error ->
            Error
    end.

process_info(Pid) when is_integer(Pid), Pid > 0 ->
    Command = io_lib:format("ps -p ~B -o pid=,pcpu=,pmem=,args=", [Pid]),
    case run_command(Command) of
        {ok, Output} ->
            case normalize_process_lines(Output) of
                [Line] ->
                    {ok, Line};
                [] ->
                    {error, <<"Process not found">>};
                [Line | _] ->
                    {ok, Line}
            end;
        Error ->
            Error
    end;
process_info(_) ->
    {error, <<"Invalid process pid">>}.

kill_process(Pid) when is_integer(Pid), Pid > 0 ->
    Command = io_lib:format("kill -TERM ~B", [Pid]),
    case run_command(Command) of
        {ok, _} -> {ok, <<"killed">>};
        Error -> Error
    end;
kill_process(_) ->
    {error, <<"Invalid process pid">>}.

spawn_background(Command, WorkingDir) ->
    FullCommand =
        <<"cd ", (shell_quote(WorkingDir))/binary,
          " && ", Command/binary,
          " >/dev/null 2>&1 & echo $!">>,
    case run_shell_command(FullCommand) of
        {ok, Output} ->
            case parse_pid(string:trim(Output)) of
                {ok, Pid} -> {ok, Pid};
                error ->
                    {error, <<"Failed to parse spawned process pid: ", Output/binary>>}
            end;
        Error ->
            Error
    end.

run_command(Command) ->
    try
        Port = open_port({spawn, Command}, [exit_status, stderr_to_stdout, binary]),
        collect_output(Port, <<>>)
    catch
        _:Reason ->
            {error, list_to_binary(io_lib:format("Command failed: ~p", [Reason]))}
    end.

run_shell_command(Command) ->
    try
        Port = open_port(
            {spawn_executable, "/bin/sh"},
            [
                exit_status,
                stderr_to_stdout,
                binary,
                {args, ["-lc", binary_to_list(Command)]}
            ]
        ),
        collect_output(Port, <<>>)
    catch
        _:Reason ->
            {error, list_to_binary(io_lib:format("Shell command failed: ~p", [Reason]))}
    end.

collect_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, string:trim(Acc, trailing, "\n")};
        {Port, {exit_status, Status}} ->
            {error, <<"Exit status ", (integer_to_binary(Status))/binary, ": ", Acc/binary>>}
    after 10000 ->
        port_close(Port),
        {error, <<"Command timed out">>}
    end.

normalize_process_lines(Output) ->
    Trimmed = string:trim(Output),
    case Trimmed of
        <<>> -> [];
        _ ->
            Lines = binary:split(Trimmed, <<"\n">>, [global]),
            lists:filtermap(
                fun(Line) ->
                    case normalize_process_line(Line) of
                        {ok, Normalized} -> {true, Normalized};
                        error -> false
                    end
                end,
                Lines
            )
    end.

normalize_process_line(Line) ->
    Tokens = re:split(string:trim(Line), "\\s+", [{return, binary}, trim]),
    case Tokens of
        [Pid, Cpu, Memory | CommandParts] when CommandParts =/= [] ->
            Command = join_binaries(CommandParts, <<" ">>),
            {ok, <<Pid/binary, "\t", Cpu/binary, "\t", Memory/binary, "\t", Command/binary>>};
        _ ->
            error
    end.

join_binaries([], _Separator) ->
    <<>>;
join_binaries([Only], _Separator) ->
    Only;
join_binaries([First | Rest], Separator) ->
    lists:foldl(
        fun(Item, Acc) -> <<Acc/binary, Separator/binary, Item/binary>> end,
        First,
        Rest
    ).

parse_pid(Value) ->
    try
        {ok, binary_to_integer(iolist_to_binary(Value))}
    catch
        _:_ -> error
    end.

shell_quote(Value) ->
    Escaped = binary:replace(Value, <<"\'">>, <<"'\''">>, [global]),
    <<"'", Escaped/binary, "'">>.
