-module(supernova_cli_ffi).
-export([get_args/0]).

%% Plain arguments after `--` for `gleam run -m module -- args`.
get_args() ->
    [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()].
