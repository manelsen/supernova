-module(webhook_test_ffi).
-export([post/4, hmac_hex/2]).

%% POST to a loopback port with headers; returns {Status, Body}.
post(Port, Path, Headers, Body) ->
    _ = application:ensure_all_started(hackney),
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), Path]),
    case hackney:request(post, Url, Headers, Body, []) of
        {ok, Status, _, RespBody} when is_binary(RespBody) -> {Status, RespBody};
        {ok, Status, _} -> {Status, <<>>};
        {error, Reason} -> {0, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

hmac_hex(Secret, Body) ->
    Mac = crypto:mac(hmac, sha256, Secret, Body),
    list_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Mac]).
