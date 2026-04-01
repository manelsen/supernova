-module(supernova_http).
-export([send/5]).

-define(DEFAULT_TIMEOUT, 120000).

send(Method, Url, Headers, Body, Timeout) ->
    ActualTimeout = case Timeout of
        undefined -> ?DEFAULT_TIMEOUT;
        0 -> infinity;
        _ -> Timeout
    end,
    Options = [
        {with_body, true},
        {recv_timeout, ActualTimeout},
        {connect_timeout, 30000}
    ],
    case hackney:request(Method, Url, Headers, Body, Options) of
        {ok, Status, ResponseHeaders, ResponseBody} ->
            {ok, {response, Status, ResponseHeaders, ResponseBody}};
        {ok, Status, ResponseHeaders} ->
            {ok, {response, Status, ResponseHeaders, <<>>}};
        {error, Error} ->
            {error, {other, Error}}
    end.
