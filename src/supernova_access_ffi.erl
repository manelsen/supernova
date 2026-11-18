-module(supernova_access_ffi).
-export([rename/2]).

%% Atomically replace To with From (POSIX rename semantics).
rename(From, To) ->
  case file:rename(From, To) of
    ok -> {ok, nil};
    {error, Reason} -> {error, list_to_binary(file:format_error(Reason))}
  end.
