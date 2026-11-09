-module(test_hackney_ffi).

-export([ensure_started/0]).

ensure_started() ->
    _ = application:ensure_all_started(hackney),
    nil.
