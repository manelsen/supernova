-module(supernova_search_ffi).
-export([request/5]).

%% One HTTP request for the probes' search (PRD-S, S-05):
%% {ok, {Status, Body}} or {error, Reason}. Bodies over 2 MB are refused.
request(Method, Url, Headers, Body, TimeoutMs) ->
    Options = [
        with_body,
        {recv_timeout, TimeoutMs},
        {connect_timeout, 5000},
        {max_body, 2 * 1024 * 1024}
    ],
    M = case Method of <<"post">> -> post; _ -> get end,
    try hackney:request(M, Url, Headers, Body, Options) of
        {ok, Status, _RespHeaders, RespBody} -> {ok, {Status, RespBody}};
        {error, Reason} -> {error, describe(Reason)}
    catch
        Class:Reason -> {error, describe({Class, Reason})}
    end.

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
