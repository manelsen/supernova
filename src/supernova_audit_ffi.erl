-module(supernova_audit_ffi).
-export([write_audit_entry/3, escape_field/1]).

%% Write an audit entry to the agent's rotating log file.
%% Log file path: <workspace_root>/<agent_id>/.supernova/audit.log
%% Rotates when file exceeds 10MB.
write_audit_entry(AgentId, LogLine, WorkspaceRoot) ->
  try
    LogDir = filename:join([WorkspaceRoot, AgentId, ".supernova"]),
    ok = ensure_dir(LogDir),
    LogFile = filename:join(LogDir, "audit.log"),
    ok = maybe_rotate(LogFile),
    Line = io_lib:format("~s~n", [LogLine]),
    case file:write_file(LogFile, Line, [append]) of
      ok -> {ok, nil};
      {error, Reason} -> {error, text("write_failed: ~p", [Reason])}
    end
  catch
    Class:Error -> {error, text("audit_write_error: ~p:~p", [Class, Error])}
  end.

%% Errors go back to Gleam as String, a binary; io_lib:format gives a list.
text(Format, Args) ->
  unicode:characters_to_binary(io_lib:format(Format, Args)).

%% Ensure the directory and its parents exist. file:make_dir created only
%% the last level, so with no <root>/<agent> yet every write failed and was
%% swallowed: no audit line ever reached the disk.
ensure_dir(Dir) ->
  filelib:ensure_path(Dir).

%% Rotate log file if it exceeds 10MB.
maybe_rotate(LogFile) ->
  case filelib:file_size(LogFile) of
    Size when Size > 10 * 1024 * 1024 ->
      rotate_file(LogFile);
    _ ->
      ok
  end.

%% Rotate: rename current to .1, .1 to .2, etc. (keep 5 backups).
rotate_file(LogFile) ->
  %% Remove oldest backup
  file:delete(LogFile ++ ".5"),
  %% Shift backups
  lists:foreach(fun(N) ->
    Src = LogFile ++ "." ++ integer_to_list(5 - N),
    Dst = LogFile ++ "." ++ integer_to_list(6 - N),
    case filelib:is_file(Src) of
      true -> file:rename(Src, Dst);
      false -> ok
    end
  end, lists:seq(0, 4)),
  %% Rename current to .1
  file:rename(LogFile, LogFile ++ ".1"),
  ok.

%% Escape an audit field byte by byte. Gleam's string.replace works on
%% grapheme clusters, so it cannot see the "\r" or "\n" inside a "\r\n"
%% cluster.
escape_field(Value) when is_binary(Value) ->
    << <<(escape_byte(B))/binary>> || <<B>> <= Value >>.

escape_byte($\\) -> <<"\\\\">>;
escape_byte($\r) -> <<"\\r">>;
escape_byte($\n) -> <<"\\n">>;
escape_byte($|) -> <<"\\x7c">>;
escape_byte(B) -> <<B>>.
