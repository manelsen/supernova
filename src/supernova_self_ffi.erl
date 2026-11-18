-module(supernova_self_ffi).
-export([has_ascii_letter/1]).

has_ascii_letter(Binary) when is_binary(Binary) ->
    lists:any(fun(C) ->
        (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
    end, binary_to_list(Binary)).
