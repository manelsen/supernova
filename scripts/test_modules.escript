#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% Run only the given test modules, for a fast TDD loop.
%% Run `gleam build` first (`make test-only` does it).
%%
%% Each argument is a test file (test/self/drift_apply_test.gleam), a test
%% directory (test/sim, every *_test.gleam below it) or a module name
%% (self@drift_apply_test). Run the full suite (`make coverage`) before a commit.

main([]) ->
  io:format("usage: test_modules.escript <test file | test dir | module>...~n"),
  halt(2);
main(Args) ->
  lists:foreach(fun code:add_patha/1, filelib:wildcard("build/dev/erlang/*/ebin")),
  _ = application:ensure_all_started(yay),
  Modules = lists:usort(lists:flatmap(fun to_modules/1, Args)),
  case [M || M <- Modules, code:which(M) =:= non_existing] of
    [] -> ok;
    Missing ->
      io:format("ERROR: no such compiled test module: ~p. Check the name, or run `gleam build`.~n", [Missing]),
      halt(2)
  end,
  io:format("Running ~p module(s)~n", [length(Modules)]),
  case eunit:test(Modules, [{scale_timeouts, 10}]) of
    ok -> halt(0);
    _ -> halt(1)
  end.

to_modules(Arg) ->
  case filelib:is_dir(Arg) of
    true ->
      Files = filelib:fold_files(Arg, ".*_test\\.gleam$", true, fun(F, Acc) -> [F | Acc] end, []),
      [file_to_module(F) || F <- Files];
    false ->
      case filename:extension(Arg) of
        ".gleam" -> [file_to_module(Arg)];
        _ -> [list_to_atom(Arg)]
      end
  end.

file_to_module(Path) ->
  Relative = strip_prefix(strip_prefix(Path, "./"), "test/"),
  Name = re:replace(filename:rootname(Relative), "/", "@", [global, {return, list}]),
  list_to_atom(Name).

strip_prefix(Path, Prefix) ->
  case lists:prefix(Prefix, Path) of
    true -> lists:nthtail(length(Prefix), Path);
    false -> Path
  end.
