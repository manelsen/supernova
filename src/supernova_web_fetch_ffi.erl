%% GET for the web_fetch tool (PRD-E, E-03): no redirects, a ceiling on the
%% body read while it arrives, and time limits on connect and receive.
-module(supernova_web_fetch_ffi).
-export([get/2]).

get(Url, MaxBytes) ->
    Options = [{follow_redirect, false},
               {max_body_size, MaxBytes},
               {connect_timeout, 8000},
               {recv_timeout, 30000}],
    try hackney:request(get, Url, [{<<"user-agent">>, <<"Supernova">>}], <<>>, Options) of
        {ok, Status, _Headers, Body} when is_binary(Body) -> {ok, {Status, Body}};
        {ok, Status, _Headers} -> {ok, {Status, <<>>}};
        {error, body_too_large} -> {error, too_large};
        {error, _} -> {error, network}
    catch
        _:_ -> {error, network}
    end.
