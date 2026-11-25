%% Signature checks for channel/webhook_server (PRD-C, C-02).
-module(supernova_webhook_ffi).
-export([hub_signature_valid/3]).

%% `sha256=<hex>` of HMAC-SHA256(Secret, Body), compared in constant time.
hub_signature_valid(<<>>, _Body, _Header) ->
    false;
hub_signature_valid(Secret, Body, <<"sha256=", Hex/binary>>) ->
    Expected = crypto:mac(hmac, sha256, Secret, Body),
    try binary:decode_hex(Hex) of
        Given when byte_size(Given) =:= byte_size(Expected) ->
            crypto:hash_equals(Given, Expected);
        _ ->
            false
    catch
        _:_ -> false
    end;
hub_signature_valid(_Secret, _Body, _Header) ->
    false.
