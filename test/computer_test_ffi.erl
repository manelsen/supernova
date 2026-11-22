-module(computer_test_ffi).
-export([serve_once/2, last_request/0]).

%% Answer one HTTP request with Status and Body on a free local port and
%% return the port. The raw request is kept for last_request/0.
serve_once(Status, Body) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Parent = self(),
    Pid = spawn(fun() ->
        receive go -> ok end,
        {ok, Sock} = gen_tcp:accept(Listen, 5000),
        Request = read_request(Sock, <<>>),
        persistent_term:put({?MODULE, last}, Request),
        Response = [
            <<"HTTP/1.1 ">>, integer_to_binary(Status), <<" X\r\n">>,
            <<"content-type: application/json\r\n">>,
            <<"content-length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n">>,
            <<"connection: close\r\n\r\n">>, Body
        ],
        ok = gen_tcp:send(Sock, Response),
        gen_tcp:close(Sock),
        gen_tcp:close(Listen),
        Parent ! served
    end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    Pid ! go,
    Port.

last_request() ->
    persistent_term:get({?MODULE, last}, <<>>).

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
        case string:lowercase(Line) of
            <<"content-length:", Value/binary>> -> binary_to_integer(string:trim(Value));
            _ -> Acc
        end
    end, 0, Lines).
