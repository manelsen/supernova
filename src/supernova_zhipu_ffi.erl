-module(supernova_zhipu_ffi).
-export([build_jwt/1]).

%% build_jwt/1 — generate a Zhipu AI JWT from an API key.
%%
%% The Zhipu API key format is "id.secret" (split on the first dot).
%% JWT structure:
%%   header  : {"alg":"HS256","sign_type":"SIGN"}
%%   payload : {"api_key":"<id>","exp":<now_ms+30000>,"timestamp":<now_ms>}
%%   signature: HMAC-SHA256(header_b64 ++ "." ++ payload_b64, secret)
%%
%% All timestamps are in MILLISECONDS (not seconds).
%%
%% Returns {ok, JWT} on success or {error, Reason} on failure.
build_jwt(ApiKey) ->
    case binary:split(ApiKey, <<".">>) of
        [Id, Secret] ->
            NowMs = erlang:system_time(millisecond),
            ExpMs = NowMs + 30000,
            Header = base64url(<<"{\"alg\":\"HS256\",\"sign_type\":\"SIGN\"}">>),
            Payload = base64url(
                list_to_binary([
                    "{\"api_key\":\"", Id, "\",",
                    "\"exp\":", integer_to_binary(ExpMs), ",",
                    "\"timestamp\":", integer_to_binary(NowMs), "}"
                ])
            ),
            Msg = <<Header/binary, ".", Payload/binary>>,
            Sig = base64url(crypto:mac(hmac, sha256, Secret, Msg)),
            JWT = <<Msg/binary, ".", Sig/binary>>,
            {ok, JWT};
        _ ->
            %% Key is not in id.secret format — treat as plain Bearer token.
            {ok, ApiKey}
    end.

%% URL-safe base64 without padding.
base64url(Bin) ->
    B64 = base64:encode(Bin),
    NoPad = binary:replace(B64, <<"=">>, <<"">>, [global]),
    Url1  = binary:replace(NoPad, <<"+">>, <<"-">>, [global]),
    binary:replace(Url1, <<"/">>, <<"_">>, [global]).
