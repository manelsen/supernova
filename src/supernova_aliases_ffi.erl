-module(supernova_aliases_ffi).
-export([locked/1]).

%% Run Fun with the alias table locked: links and unlinks never interleave.
locked(Fun) ->
    global:trans({supernova_aliases, self()}, Fun, [node()], infinity).
