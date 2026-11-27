%% GET for the web_fetch tool (PRD-E, E-03): no redirects, a ceiling on the
%% body read while it arrives, and time limits on connect and receive.
%%
%% get/2 fetches a URL Supernova trusts (WhatsApp's bridge, from the
%% configuration). get_public/2 is the agent's: the name is resolved here
%% once, every address is checked, and the connection goes to the checked
%% address (Qwen 4, M7). A name that answered a public address to the URL
%% guard and answers an internal one a moment later (DNS rebinding) never
%% gets a connection. The Host header, the TLS SNI and the certificate check
%% keep the name.
-module(supernova_web_fetch_ffi).
-export([get/2, get_public/2, pin/1]).

get(Url, MaxBytes) ->
    request(Url, [], [], MaxBytes).

get_public(Url, MaxBytes) ->
    case pin(Url) of
        {ok, Target, Headers, Extra} -> request(Target, Headers, Extra, MaxBytes);
        {error, blocked} -> {error, blocked};
        {error, _} -> {error, network}
    end.

request(Target, Headers, Extra, MaxBytes) ->
    Options = Extra ++ [{follow_redirect, false},
                        {max_body_size, MaxBytes},
                        {connect_timeout, 8000},
                        {recv_timeout, 30000}],
    try hackney:request(get, Target, [{<<"user-agent">>, <<"Supernova">>} | Headers], <<>>, Options) of
        {ok, Status, _Headers, Body} when is_binary(Body) -> {ok, {Status, Body}};
        {ok, Status, _Headers} -> {ok, {Status, <<>>}};
        {error, body_too_large} -> {error, too_large};
        {error, _} -> {error, network}
    catch
        _:_ -> {error, network}
    end.

%% The URL to connect to, on the checked address, with the headers and
%% options that keep the name.
pin(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = Parts when Host =/= <<>> ->
            case inet:parse_strict_address(binary_to_list(Host)) of
                {ok, _} ->
                    %% A literal address: the guard checked it, nothing to resolve.
                    {ok, Url, [], []};
                {error, _} ->
                    pin_name(Scheme, Host, Parts)
            end;
        _ ->
            {error, invalid}
    end.

pin_name(Scheme, Host, Parts) ->
    case supernova_url_guard_ffi:resolve(Host) of
        {ok, Addresses} ->
            case lists:any(fun supernova_url_guard_ffi:address_blocked/1, Addresses) of
                true -> {error, blocked};
                false ->
                    Address = pick(Addresses),
                    Target = uri_string:recompose(Parts#{host := url_host(Address)}),
                    HostHeader = case Parts of
                        #{port := Port} when is_integer(Port) ->
                            <<Host/binary, ":", (integer_to_binary(Port))/binary>>;
                        _ -> Host
                    end,
                    Extra = case string:lowercase(Scheme) of
                        <<"https">> ->
                            [{ssl_options, [{server_name_indication, binary_to_list(Host)}]}];
                        _ -> []
                    end,
                    %% HTTP/1.1 only: HTTP/2 would send the address as
                    %% :authority and drop the Host header with the name.
                    {ok, Target, [{<<"host">>, HostHeader}], [{protocols, [http1]} | Extra]}
            end;
        {error, _} ->
            {error, unresolved}
    end.

%% An IPv4 address when there is one.
pick(Addresses) ->
    case [A || A <- Addresses, binary:match(A, <<":">>) =:= nomatch] of
        [V4 | _] -> V4;
        [] -> hd(Addresses)
    end.

url_host(Address) ->
    case binary:match(Address, <<":">>) of
        nomatch -> Address;
        _ -> <<"[", Address/binary, "]">>
    end.
