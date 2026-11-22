-module(supernova_computer_ffi).
-export([run/4]).

%% POST a JSON request to the computer service and return
%% {ok, {Status, BodyWithoutImage, Image}} or {error, Reason}.
%%
%% The screenshot comes back base64-encoded inside the JSON; it is taken out
%% here so the Gleam side only handles the small rest of the answer and the
%% image travels on its own. Image is <<>> when there is none.
run(Url, Token, Body, TimeoutMs) ->
    Headers0 = [{<<"content-type">>, <<"application/json">>}],
    Headers = case Token of
        <<>> -> Headers0;
        _ -> [{<<"authorization">>, <<"Bearer ", Token/binary>>} | Headers0]
    end,
    Options = [
        with_body,
        {recv_timeout, TimeoutMs},
        {connect_timeout, 5000},
        {max_body, 16 * 1024 * 1024}
    ],
    try hackney:request(post, Url, Headers, Body, Options) of
        {ok, Status, _RespHeaders, RespBody} ->
            {ok, split_image(Status, RespBody)};
        {error, Reason} ->
            {error, describe(Reason)}
    catch
        Class:Reason ->
            {error, describe({Class, Reason})}
    end.

split_image(Status, RespBody) ->
    try json:decode(RespBody) of
        Map when is_map(Map) ->
            case maps:take(<<"image">>, Map) of
                {Image, Rest} when is_binary(Image) ->
                    {Status, iolist_to_binary(json:encode(Rest)), Image};
                _ ->
                    {Status, RespBody, <<>>}
            end;
        _ ->
            {Status, RespBody, <<>>}
    catch
        _:_ -> {Status, RespBody, <<>>}
    end.

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
