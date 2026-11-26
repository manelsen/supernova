-module(mcp_computer_fake_ffi).
-export([start/1, requests/1, stop/1]).

%% A fake computer service: answers every HTTP request with Responder(Body),
%% which returns {Status, ResponseBody}, on a free local port. Requests are
%% kept, raw, for requests/1.
start(Responder) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Table = ets:new(fake_computer, [public, bag]),
    Pid = spawn(fun() -> accept_loop(Listen, Responder, Table) end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    {Port, Pid, Table}.

requests({_Port, _Pid, Table}) ->
    Rows = lists:sort(ets:tab2list(Table)),
    [Request || {_, Request} <- Rows].

stop({_Port, Pid, _Table}) ->
    exit(Pid, kill),
    nil.

accept_loop(Listen, Responder, Table) ->
    case gen_tcp:accept(Listen) of
        {ok, Sock} ->
            Request = read_request(Sock, <<>>),
            ets:insert(Table, {erlang:unique_integer([monotonic]), Request}),
            Body = body_of(Request),
            {Status, Answer} = Responder(Body),
            Response = [
                <<"HTTP/1.1 ">>, integer_to_binary(Status), <<" X\r\n">>,
                <<"content-type: application/json\r\n">>,
                <<"content-length: ">>, integer_to_binary(byte_size(Answer)), <<"\r\n">>,
                <<"connection: close\r\n\r\n">>, Answer
            ],
            gen_tcp:send(Sock, Response),
            gen_tcp:close(Sock),
            accept_loop(Listen, Responder, Table);
        {error, _} ->
            ok
    end.

body_of(Request) ->
    case binary:split(Request, <<"\r\n\r\n">>) of
        [_, Body] -> Body;
        _ -> <<>>
    end.

read_request(Sock, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            Length = content_length(Head),
            read_body(Sock, Head, Rest, Length);
        [_] ->
            {ok, More} = gen_tcp:recv(Sock, 0, 5000),
            read_request(Sock, <<Acc/binary, More/binary>>)
    end.

read_body(_Sock, Head, Body, Length) when byte_size(Body) >= Length ->
    <<Head/binary, "\r\n\r\n", Body/binary>>;
read_body(Sock, Head, Body, Length) ->
    {ok, More} = gen_tcp:recv(Sock, 0, 5000),
    read_body(Sock, Head, <<Body/binary, More/binary>>, Length).

content_length(Head) ->
    Lines = binary:split(Head, <<"\r\n">>, [global]),
    lists:foldl(fun(Line, Acc) ->
        case binary:split(string:lowercase(Line), <<":">>) of
            [<<"content-length">>, Value] -> binary_to_integer(string:trim(Value));
            _ -> Acc
        end
    end, 0, Lines).
