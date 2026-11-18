#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

main(Args) ->
  Threshold = parse_threshold(Args),
  add_code_paths(),
  case ensure_test_beams_present() of
    ok ->
      ok;
    {error, Message} ->
      io:format("ERROR: ~s~n", [Message]),
      halt(2)
  end,
  start_cover(),
  SrcModules = source_modules(),
  case compile_source_modules(SrcModules) of
    ok ->
      ok;
    {error, MissingBeams} ->
      print_missing_beams(MissingBeams),
      halt(2)
  end,
  TestResult = run_tests(),
  Summary = summarize_coverage(SrcModules),
  print_summary(Summary, Threshold, TestResult),
  case gate_passes(Summary, Threshold, TestResult) of
    true -> halt(0);
    false -> halt(1)
  end.

parse_threshold(Args) ->
  parse_threshold(Args, 85.0).

parse_threshold([], Default) ->
  Default;
parse_threshold(["--threshold", Value | _], _Default) ->
  parse_number(Value);
parse_threshold([Arg | Rest], Default) ->
  Prefix = "--threshold=",
  case lists:prefix(Prefix, Arg) of
    true ->
      Value = lists:nthtail(length(Prefix), Arg),
      parse_number(Value);
    false ->
      parse_threshold(Rest, Default)
  end.

parse_number(Value) ->
  case string:to_float(Value) of
    {Float, ""} ->
      Float;
    {error, no_float} ->
      case string:to_integer(Value) of
        {Int, ""} ->
          Int * 1.0;
        _ ->
          io:format("ERROR: invalid threshold '~s' (expected number)~n", [Value]),
          halt(2)
      end;
    _ ->
      io:format("ERROR: invalid threshold '~s' (expected number)~n", [Value]),
      halt(2)
  end.

add_code_paths() ->
  Paths = filelib:wildcard("build/dev/erlang/*/ebin"),
  lists:foreach(fun(Path) -> code:add_patha(Path) end, Paths).

ensure_test_beams_present() ->
  case filelib:wildcard("build/dev/erlang/supernova/ebin/*_test.beam") of
    [] ->
      {error, "no compiled test beams found. Run `gleam test` first."};
    _ ->
      ok
  end.

start_cover() ->
  case cover:start() of
    {ok, _Pid} -> ok;
    {error, {already_started, _Pid}} -> ok
  end.

source_modules() ->
  SourceFiles =
    filelib:fold_files("src", ".*\\.gleam$", true, fun(File, Acc) -> [File | Acc] end, []),
  lists:usort(lists:map(fun source_file_to_module/1, SourceFiles)).

source_file_to_module(Path) ->
  RelativePath = strip_prefix(Path, "src/"),
  list_to_atom(path_to_module_name(filename:rootname(RelativePath))).

test_modules() ->
  TestFiles =
    filelib:fold_files("test", ".*\\.(gleam|erl)$", true, fun(File, Acc) -> [File | Acc] end, []),
  lists:usort(lists:map(fun test_file_to_module/1, TestFiles)).

test_file_to_module(Path) ->
  RelativePath = strip_prefix(Path, "test/"),
  case filename:extension(RelativePath) of
    ".gleam" ->
      list_to_atom(path_to_module_name(filename:rootname(RelativePath)));
    ".erl" ->
      list_to_atom(filename:rootname(filename:basename(RelativePath)))
  end.

path_to_module_name(Path) ->
  re:replace(Path, "/", "@", [global, {return, list}]).

strip_prefix(Path, Prefix) ->
  case lists:prefix(Prefix, Path) of
    true -> lists:nthtail(length(Prefix), Path);
    false -> Path
  end.

compile_source_modules(Modules) ->
  Missing =
    lists:foldl(
      fun(Module, MissingAcc) ->
        BeamPath = module_beam_path(Module),
        case filelib:is_file(BeamPath) of
          true ->
            _ = cover:compile_beam(BeamPath),
            MissingAcc;
          false ->
            [BeamPath | MissingAcc]
        end
      end,
      [],
      Modules
    ),
  case Missing of
    [] -> ok;
    _ -> {error, lists:reverse(Missing)}
  end.

module_beam_path(Module) ->
  "build/dev/erlang/supernova/ebin/" ++ atom_to_list(Module) ++ ".beam".

print_missing_beams(MissingBeams) ->
  io:format("ERROR: missing compiled source beams:~n", []),
  lists:foreach(fun(Path) -> io:format("  - ~s~n", [Path]) end, MissingBeams).

run_tests() ->
  ensure_runtime_apps_started(),
  eunit:test(test_modules(), [no_tty, {scale_timeouts, 10}]).

ensure_runtime_apps_started() ->
  _ = application:ensure_all_started(yay),
  ok.

summarize_coverage(Modules) ->
  lists:foldl(fun summarize_module/2, #{covered => 0, not_covered => 0, modules => []}, Modules).

summarize_module(Module, Summary) ->
  case cover:analyse(Module, coverage, module) of
    {ok, {_Name, {Covered, NotCovered}}} ->
      Total = Covered + NotCovered,
      ModulePct = percent(Covered, Total),
      #{
        covered := CurrentCovered,
        not_covered := CurrentNotCovered,
        modules := CurrentModules
      } = Summary,
      Summary#{
        covered => CurrentCovered + Covered,
        not_covered => CurrentNotCovered + NotCovered,
        modules => [{ModulePct, Module, Covered, Total} | CurrentModules]
      };
    _ ->
      Summary
  end.

print_summary(Summary, Threshold, TestResult) ->
  Covered = maps:get(covered, Summary),
  NotCovered = maps:get(not_covered, Summary),
  Total = Covered + NotCovered,
  CoveragePct = percent(Covered, Total),
  io:format("Line coverage: ~.2f% (~p/~p)~n", [CoveragePct, Covered, Total]),
  io:format("Threshold: ~.2f%~n", [Threshold]),
  io:format("Tests: ~p~n", [TestResult]),
  ModuleRows = maps:get(modules, Summary),
  print_worst_modules(ModuleRows),
  print_largest_gaps(ModuleRows).

print_worst_modules(ModuleRows) ->
  Sorted =
    lists:sort(
      fun({PctA, _, _, _}, {PctB, _, _, _}) ->
        PctA =< PctB
      end,
      ModuleRows
    ),
  io:format("Lowest-covered modules (top 10):~n", []),
  Top10 = lists:sublist(Sorted, 10),
  lists:foreach(
    fun({Pct, Module, Covered, Total}) ->
      io:format("  - ~s: ~.2f% (~p/~p)~n", [atom_to_list(Module), Pct, Covered, Total])
    end,
    Top10
  ).

print_largest_gaps(ModuleRows) ->
  Sorted =
    lists:sort(
      fun({_, _, CoveredA, TotalA}, {_, _, CoveredB, TotalB}) ->
        (TotalA - CoveredA) >= (TotalB - CoveredB)
      end,
      ModuleRows
    ),
  io:format("Largest uncovered line gaps (top 10):~n", []),
  Top10 = lists:sublist(Sorted, 10),
  lists:foreach(
    fun({Pct, Module, Covered, Total}) ->
      Uncovered = Total - Covered,
      io:format(
        "  - ~s: ~p uncovered (~p/~p, ~.2f%)~n",
        [atom_to_list(Module), Uncovered, Covered, Total, Pct]
      )
    end,
    Top10
  ).

percent(_Covered, 0) ->
  0.0;
percent(Covered, Total) ->
  (Covered * 100.0) / Total.

gate_passes(Summary, Threshold, TestResult) ->
  Covered = maps:get(covered, Summary),
  NotCovered = maps:get(not_covered, Summary),
  Total = Covered + NotCovered,
  CoveragePct = percent(Covered, Total),
  TestResult =:= ok andalso CoveragePct >= Threshold.
