-module(supernova_harness_ffi).
-export([run/4, process_alive/1, json_first_key/1, json_encode/1,
         free_port/0, random_token/0, http_post/4, http_get/3, cwd/0,
         dir_exists/1, remove_dir/1, scratch_dir/0]).

%% Run an executable with its arguments passed verbatim, capturing stdout
%% only (stderr is not mixed into the JSON the caller parses).
%% stdin is /dev/null: CLIs such as `claude -p` read a piped stdin until EOF,
%% and an Erlang port cannot close its write end without closing the port.
%% The fixed launcher `exec "$0" "$@" </dev/null` receives the executable and
%% every argument as positional parameters, so nothing is interpolated by sh.
%% On timeout the OS process is killed before the port is closed.
run(Path, Args, Cwd, Timeout) when is_binary(Path), is_list(Args) ->
    Args1 = [binary_to_list(Arg) || Arg <- Args],
    Port =
        open_port(
            {spawn_executable, "/bin/sh"},
            [{args, ["-c", "exec \"$0\" \"$@\" </dev/null",
                     binary_to_list(Path) | Args1]},
             {cd, binary_to_list(Cwd)},
             exit_status,
             binary,
             use_stdio]
        ),
    collect(Port, [], Timeout).

collect(Port, Acc, Timeout) ->
    receive
        {Port, {data, Chunk}} ->
            collect(Port, [Chunk | Acc], Timeout);
        {Port, {exit_status, Status}} ->
            {ok, {Status, iolist_to_binary(lists:reverse(Acc))}}
    after Timeout ->
        OsPid = case erlang:port_info(Port, os_pid) of
            {os_pid, Child} -> Child;
            _ -> undefined
        end,
        case OsPid of
            undefined -> ok;
            Child1 when is_integer(Child1) ->
                _ = os:cmd("kill -9 " ++ integer_to_list(Child1)),
                ok
        end,
        catch port_close(Port),
        {error, timeout}
    end.

%% A killed process stays in /proc as a zombie until its parent reaps it;
%% the timeout test read that window as "still alive". A zombie is dead.
process_alive(Pid) when is_integer(Pid) ->
    case file:read_file("/proc/" ++ integer_to_list(Pid) ++ "/stat") of
        {ok, Stat} ->
            case binary:split(Stat, <<") ">>) of
                [_, <<"Z", _/binary>>] -> false;
                [_, <<"X", _/binary>>] -> false;
                _ -> true
            end;
        {error, _} -> false
    end.

json_first_key(Map) when is_map(Map) ->
    case maps:keys(Map) of
        [Key | _] when is_binary(Key) -> Key;
        [Key | _] -> unicode:characters_to_binary(io_lib:format("~p", [Key]));
        [] -> <<>>
    end;
json_first_key(_) ->
    <<>>.

json_encode(Term) ->
    unicode:characters_to_binary(json:encode(Term)).

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

random_token() ->
    Bytes = crypto:strong_rand_bytes(24),
    unicode:characters_to_binary(
        [io_lib:format("~2.16.0b", [B]) || <<B>> <= Bytes]
    ).

http_post(Port, Path, Token, Body) ->
    http_request(post, Port, Path, Token, Body).

http_get(Port, Path, Token) ->
    http_request(get, Port, Path, Token, <<>>).

http_request(Method, Port, Path, Token, Body) ->
    Url = lists:concat(["http://127.0.0.1:", Port, binary_to_list(Path)]),
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Token)},
               {"content-type", "application/json"}],
    Request = case Method of
        get -> {Url, Headers};
        _ -> {Url, Headers, "application/json", Body}
    end,
    _ = application:ensure_all_started(inets),
    case httpc:request(Method, Request, [{timeout, 310000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, ResponseBody}} -> {ok, {Status, ResponseBody}};
        {error, Reason} -> {error, Reason}
    end.

cwd() ->
    {ok, Dir} = file:get_cwd(),
    unicode:characters_to_binary(Dir).

dir_exists(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(3, Info) =:= directory;
        _ -> false
    end.

remove_dir(Path) ->
    _ = file:del_dir_r(Path),
    ok.

%% An empty working directory for model CLIs, outside any repository, so no
%% AGENTS.md or CLAUDE.md is picked up. Created once per VM under /tmp (not
%% TMPDIR, which may point inside a checkout), with an unpredictable name,
%% exclusively (make_dir fails if the name exists) and mode 0700, so another
%% local user cannot pre-create it or plant symlinks in it.
scratch_dir() ->
    case persistent_term:get({supernova_harness, scratch_dir}, undefined) of
        undefined ->
            Dir = make_private_dir(10),
            Bin = unicode:characters_to_binary(Dir),
            persistent_term:put({supernova_harness, scratch_dir}, Bin),
            Bin;
        Dir ->
            Dir
    end.

make_private_dir(0) ->
    erlang:error(scratch_dir_unavailable);
make_private_dir(Tries) ->
    Suffix = [io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:strong_rand_bytes(16)],
    Dir = lists:flatten(["/tmp/supernova-harness-", Suffix]),
    case file:make_dir(Dir) of
        ok ->
            ok = file:change_mode(Dir, 8#700),
            Dir;
        {error, eexist} ->
            make_private_dir(Tries - 1);
        {error, Reason} ->
            erlang:error({scratch_dir_unavailable, Reason})
    end.
