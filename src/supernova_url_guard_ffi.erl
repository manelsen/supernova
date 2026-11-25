%% Address classification for supernova/core/url_guard (PRD-E, E-02).
-module(supernova_url_guard_ffi).
-export([host_kind/1, resolve/1, address_blocked/1]).

%% literal: a canonical IPv4 or IPv6 address; ambiguous: a numeric form the
%% resolver would read as an address (decimal, octal, hex, short dotted);
%% name: anything else.
host_kind(Host) ->
    H = binary_to_list(Host),
    case inet:parse_strict_address(H) of
        {ok, _} -> literal;
        {error, _} ->
            case inet:parse_address(H) of
                {ok, _} -> ambiguous;
                {error, _} ->
                    case lists:all(fun is_numeric_char/1, H) of
                        true -> ambiguous;
                        false -> name
                    end
            end
    end.

is_numeric_char(C) ->
    (C >= $0 andalso C =< $9) orelse C =:= $. orelse C =:= $x orelse C =:= $X
        orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F).

%% Every A and AAAA address of a name, as text.
resolve(Host) ->
    H = binary_to_list(Host),
    V4 = case inet:getaddrs(H, inet) of {ok, A} -> A; _ -> [] end,
    V6 = case inet:getaddrs(H, inet6) of {ok, B} -> B; _ -> [] end,
    case V4 ++ V6 of
        [] -> {error, nil};
        All -> {ok, [list_to_binary(inet:ntoa(X)) || X <- lists:usort(All)]}
    end.

%% True when an address must not be reached from a tool; unparseable text is
%% blocked.
address_blocked(Text) ->
    case inet:parse_strict_address(binary_to_list(Text)) of
        {ok, Addr} -> blocked(Addr);
        {error, _} -> true
    end.

blocked({0, _, _, _}) -> true;
blocked({10, _, _, _}) -> true;
blocked({127, _, _, _}) -> true;
blocked({100, B, _, _}) when B >= 64, B < 128 -> true;
blocked({169, 254, _, _}) -> true;
blocked({172, B, _, _}) when B >= 16, B < 32 -> true;
blocked({192, 0, 0, _}) -> true;
blocked({192, 168, _, _}) -> true;
blocked({198, B, _, _}) when B =:= 18; B =:= 19 -> true;
blocked({A, _, _, _}) when A >= 224 -> true;
blocked({_, _, _, _}) -> false;
blocked({0, 0, 0, 0, 0, 0, 0, 0}) -> true;
blocked({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
%% IPv4-mapped and IPv4-compatible
blocked({0, 0, 0, 0, 0, 16#ffff, H, L}) -> blocked(v4(H, L));
blocked({0, 0, 0, 0, 0, 0, H, L}) -> blocked(v4(H, L));
%% NAT64
blocked({16#64, 16#ff9b, 0, 0, 0, 0, H, L}) -> blocked(v4(H, L));
%% 6to4
blocked({16#2002, H, L, _, _, _, _, _}) -> blocked(v4(H, L));
blocked({A, _, _, _, _, _, _, _}) when A band 16#ffc0 =:= 16#fe80 -> true;
blocked({A, _, _, _, _, _, _, _}) when A band 16#ffc0 =:= 16#fec0 -> true;
blocked({A, _, _, _, _, _, _, _}) when A band 16#fe00 =:= 16#fc00 -> true;
blocked({A, _, _, _, _, _, _, _}) when A band 16#ff00 =:= 16#ff00 -> true;
blocked({_, _, _, _, _, _, _, _}) -> false.

v4(H, L) -> {H bsr 8, H band 255, L bsr 8, L band 255}.
