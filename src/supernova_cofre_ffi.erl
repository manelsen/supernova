-module(supernova_cofre_ffi).
-export([seal/2, open/2]).

%% The vault's cipher (PRD-K, K12, K13): AES-256-GCM, a fresh 12-byte IV per
%% secret, the key the SHA-256 of SUPERNOVA_COFRE_KEY. A sealed secret is
%% base64(IV || tag || ciphertext).
key(Secret) -> crypto:hash(sha256, Secret).

seal(Secret, Plain) ->
    IV = crypto:strong_rand_bytes(12),
    {Cipher, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, key(Secret), IV, Plain, <<"cofre">>, 16, true),
    base64:encode(<<IV/binary, Tag/binary, Cipher/binary>>).

open(Secret, Sealed) ->
    try
        <<IV:12/binary, Tag:16/binary, Cipher/binary>> = base64:decode(Sealed),
        case crypto:crypto_one_time_aead(aes_256_gcm, key(Secret), IV, Cipher, <<"cofre">>, Tag, false) of
            error -> {error, nil};
            Plain -> {ok, Plain}
        end
    catch _:_ -> {error, nil}
    end.
