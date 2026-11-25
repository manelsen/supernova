-module(supernova_gemini_fake_ffi).
-export([read/1]).
read(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        _ -> {error, nil}
    end.
