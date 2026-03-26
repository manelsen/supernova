-module(supernova_telegram_ffi).

-export([send/5]).

send(Method, Url, Headers, Body, RecvTimeoutMs) ->
    NormalizedMethod =
        case Method of
            <<"GET">> -> get;
            <<"POST">> -> post;
            <<"PUT">> -> put;
            <<"PATCH">> -> patch;
            <<"DELETE">> -> delete;
            "GET" -> get;
            "POST" -> post;
            "PUT" -> put;
            "PATCH" -> patch;
            "DELETE" -> delete;
            _ -> get
        end,
    Options = [{with_body, true}, {recv_timeout, RecvTimeoutMs}],
    case hackney:request(NormalizedMethod, Url, Headers, Body, Options) of
        {ok, Status, ResponseHeaders, ResponseBody} ->
            {ok, {response, Status, ResponseHeaders, ResponseBody}};
        {ok, Status, ResponseHeaders} ->
            {ok, {response, Status, ResponseHeaders, <<>>}};
        {error, Error} ->
            {error, normalize_error(Error)}
    end.

normalize_error(timeout) ->
    <<"timeout">>;
normalize_error({closed, timeout}) ->
    <<"timeout">>;
normalize_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
