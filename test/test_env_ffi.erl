-module(test_env_ffi).
-export([get_env/1, set_env/2, unset_env/1]).

get_env(Key) ->
  case os:getenv(binary_to_list(Key)) of
    false -> {error, nil};
    Val -> {ok, list_to_binary(Val)}
  end.

set_env(Key, Value) ->
  true = os:putenv(binary_to_list(Key), binary_to_list(Value)),
  nil.

unset_env(Key) ->
  os:unsetenv(binary_to_list(Key)),
  nil.
