-module(harness_test_ffi).
-export([mode/1]).

%% Permission bits of a path, or -1 when it cannot be read.
mode(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(8, Info) band 8#777;
        _ -> -1
    end.
