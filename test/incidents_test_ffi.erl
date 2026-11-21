-module(incidents_test_ffi).
-export([make_unreadable/1, make_readable/1]).

%% Error when the file is still readable afterwards (running as root).
make_unreadable(Path) ->
    ok = file:change_mode(Path, 8#000),
    case file:read_file(Path) of
        {ok, _} -> file:change_mode(Path, 8#600), {error, nil};
        {error, _} -> {ok, nil}
    end.

make_readable(Path) ->
    case file:change_mode(Path, 8#600) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.
