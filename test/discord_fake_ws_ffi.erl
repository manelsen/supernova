-module(discord_fake_ws_ffi).
%% A minimal WebSocket server for the Discord gateway fake (tests only).
%%
%% Each accepted connection is a process. It reports to the Gleam subject
%% `Events`: {connected, Pid}, {received, Pid, Text} for every text frame
%% from the client, and {closed, Pid} when the connection ends. The test
%% drives it with send_text/2, close/2 (close frame with a code) and drop/1
%% (TCP close without a close frame).
-export([start/1, send_text/2, close/2, drop/1]).

-define(GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).

start(Events) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false},
                                      {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Acceptor = spawn(fun() -> receive go -> accept(Listen, Events) end end),
    ok = gen_tcp:controlling_process(Listen, Acceptor),
    Acceptor ! go,
    Port.

send_text(Pid, Text) -> Pid ! {send, Text}, nil.
close(Pid, Code) -> Pid ! {close, Code}, nil.
drop(Pid) -> Pid ! drop, nil.

accept(Listen, Events) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Pid = spawn(fun() -> receive {go, S} -> handshake(S, Events) end end),
            ok = gen_tcp:controlling_process(Socket, Pid),
            Pid ! {go, Socket},
            accept(Listen, Events);
        {error, _} -> ok
    end.

handshake(Socket, Events) ->
    case read_headers(Socket, <<>>) of
        {ok, Request} ->
            Key = header(Request, <<"sec-websocket-key">>),
            Accept = base64:encode(crypto:hash(sha, <<Key/binary, ?GUID/binary>>)),
            ok = gen_tcp:send(Socket, [<<"HTTP/1.1 101 Switching Protocols\r\n"
                                         "Upgrade: websocket\r\n"
                                         "Connection: Upgrade\r\n"
                                         "Sec-WebSocket-Accept: ">>, Accept,
                                       <<"\r\n\r\n">>]),
            ok = inet:setopts(Socket, [{active, once}]),
            gleam@erlang@process:send(Events, {connected, self()}),
            loop(Socket, Events, <<>>);
        error ->
            gen_tcp:close(Socket)
    end.

read_headers(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} -> read_headers(Socket, <<Acc/binary, Data/binary>>);
                {error, _} -> error
            end;
        _ -> {ok, Acc}
    end.

header(Request, Name) ->
    Lines = binary:split(Request, <<"\r\n">>, [global]),
    find_header(Lines, Name).

find_header([], _) -> <<>>;
find_header([Line | Rest], Name) ->
    case binary:split(Line, <<":">>) of
        [K, V] ->
            case string:lowercase(string:trim(K)) of
                Name -> string:trim(V);
                _ -> find_header(Rest, Name)
            end;
        _ -> find_header(Rest, Name)
    end.

loop(Socket, Events, Buffer) ->
    receive
        {tcp, Socket, Data} ->
            case frames(<<Buffer/binary, Data/binary>>, Socket, Events) of
                {continue, Rest} ->
                    ok = inet:setopts(Socket, [{active, once}]),
                    loop(Socket, Events, Rest);
                closed ->
                    finish(Socket, Events)
            end;
        {tcp_closed, Socket} ->
            gleam@erlang@process:send(Events, {closed, self()});
        {send, Text} ->
            gen_tcp:send(Socket, frame(1, Text)),
            loop(Socket, Events, Buffer);
        {close, Code} ->
            gen_tcp:send(Socket, frame(8, <<Code:16>>)),
            finish(Socket, Events);
        drop ->
            finish(Socket, Events)
    end.

finish(Socket, Events) ->
    gen_tcp:close(Socket),
    gleam@erlang@process:send(Events, {closed, self()}).

%% Client frames are masked; fragmentation is not used by the client.
frames(Buffer, Socket, Events) ->
    case decode(Buffer) of
        more -> {continue, Buffer};
        {Op, Payload, Rest} ->
            case Op of
                1 ->
                    gleam@erlang@process:send(Events, {received, self(), Payload}),
                    frames(Rest, Socket, Events);
                8 ->
                    gen_tcp:send(Socket, frame(8, Payload)),
                    closed;
                9 ->
                    gen_tcp:send(Socket, frame(10, Payload)),
                    frames(Rest, Socket, Events);
                _ ->
                    frames(Rest, Socket, Events)
            end
    end.

decode(<<_:4, Op:4, 1:1, 126:7, Len:16, Mask:4/binary, Rest/binary>>)
  when byte_size(Rest) >= Len ->
    payload(Op, Len, Mask, Rest);
decode(<<_:4, Op:4, 1:1, 127:7, Len:64, Mask:4/binary, Rest/binary>>)
  when byte_size(Rest) >= Len ->
    payload(Op, Len, Mask, Rest);
decode(<<_:4, Op:4, 1:1, Len:7, Mask:4/binary, Rest/binary>>)
  when Len < 126, byte_size(Rest) >= Len ->
    payload(Op, Len, Mask, Rest);
decode(_) -> more.

payload(Op, Len, Mask, Rest) ->
    <<Masked:Len/binary, Tail/binary>> = Rest,
    {Op, unmask(Masked, Mask, 0, <<>>), Tail}.

unmask(<<>>, _, _, Acc) -> Acc;
unmask(<<B, Rest/binary>>, Mask, I, Acc) ->
    M = binary:at(Mask, I rem 4),
    unmask(Rest, Mask, I + 1, <<Acc/binary, (B bxor M)>>).

frame(Op, Payload) ->
    Len = byte_size(Payload),
    Header = if
        Len < 126 -> <<1:1, 0:3, Op:4, 0:1, Len:7>>;
        Len < 65536 -> <<1:1, 0:3, Op:4, 0:1, 126:7, Len:16>>;
        true -> <<1:1, 0:3, Op:4, 0:1, 127:7, Len:64>>
    end,
    <<Header/binary, Payload/binary>>.
