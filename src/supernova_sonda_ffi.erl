-module(supernova_sonda_ffi).
-export([spent_reset/0, spent_add/1, spent/0]).

%% What the probe running in this process has spent, in US$ (PRD-S, S12).
%% The executor admits and records each model call in the process that runs
%% the loop, so the process dictionary is enough and nothing is shared.
spent_reset() -> erase(supernova_sonda_spent), nil.

spent_add(Usd) ->
    put(supernova_sonda_spent, spent() + Usd),
    nil.

spent() ->
    case get(supernova_sonda_spent) of
        undefined -> 0.0;
        Value -> Value
    end.
