-module(supernova_agent_identity_ffi).
-export([encode_principal/1, decode_principal/1]).

encode_principal(Principal) when is_binary(Principal) ->
    iolist_to_binary([encode_byte(C) || <<C>> <= Principal]).

encode_byte($:) -> <<"_">>;
encode_byte(C) when C >= $a, C =< $z -> <<C>>;
encode_byte(C) when C >= $A, C =< $Z -> <<C>>;
encode_byte(C) when C >= $0, C =< $9 -> <<C>>;
encode_byte($-) -> <<"-">>;
encode_byte($_) -> <<"_">>;
encode_byte(C) ->
    Hex = io_lib:format("%~2.16.0B", [C]),
    iolist_to_binary(Hex).

decode_principal(Encoded) when is_binary(Encoded) ->
    decode(Encoded, []).

decode(<<>>, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
decode(<<"%", H1, H2, Rest/binary>>, Acc) ->
    Byte = list_to_integer([H1, H2], 16),
    decode(Rest, [Byte | Acc]);
decode(<<"_", Rest/binary>>, Acc) ->
    decode(Rest, [$: | Acc]);
decode(<<C, Rest/binary>>, Acc) ->
    decode(Rest, [C | Acc]).
