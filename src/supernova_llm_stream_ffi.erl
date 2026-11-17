-module(supernova_llm_stream_ffi).
-export([start_request/3, read_chunk/2, cancel_request/1]).

%% Start a streaming HTTP request.
%% Returns {ok, RequestId} or {error, Reason}.
start_request(Url, Headers, Body) ->
  try
    ReqHeaders = [{to_binary(K), to_binary(V)} || {K, V} <- Headers],
    Opts = [async, {stream_to, self()}],
    case hackney:request(post, Url, ReqHeaders, Body, Opts) of
      {ok, ClientHandle} ->
        {ok, encode_handle(ClientHandle)};
      {error, Reason} ->
        {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end
  catch
    _:E -> {error, list_to_binary(io_lib:format("~p", [E]))}
  end.

%% Read the next chunk from a streaming request.
%% Returns {ok, Data} | {done} | {error, Reason}.
read_chunk(RequestIdBin, TimeoutMs) ->
  try
    RequestId = decode_handle(RequestIdBin),
    receive
      {hackney_response, RequestId, {status, _Status, _Reason}} ->
        read_chunk(RequestIdBin, TimeoutMs);
      {hackney_response, RequestId, {headers, _Headers}} ->
        read_chunk(RequestIdBin, TimeoutMs);
      {hackney_response, RequestId, done} ->
        {done};
      {hackney_response, RequestId, {error, Reason}} ->
        {error, list_to_binary(io_lib:format("~p", [Reason]))};
      {hackney_response, RequestId, Bin} when is_binary(Bin) ->
        {ok, Bin}
    after TimeoutMs ->
      {error, <<"timeout">>}
    end
  catch
    _:E -> {error, list_to_binary(io_lib:format("~p", [E]))}
  end.

%% Cancel a streaming request.
cancel_request(RequestIdBin) ->
  try
    RequestId = decode_handle(RequestIdBin),
    hackney:close(RequestId)
  catch
    _:_ -> nil
  end,
  nil.

to_binary(Val) when is_binary(Val) -> Val;
to_binary(Val) when is_list(Val) -> list_to_binary(Val).

%% Hackney 4.x returns a connection PID for async requests; 1.x returned a ref.
encode_handle(Handle) when is_pid(Handle) ->
  list_to_binary(pid_to_list(Handle));
encode_handle(Handle) when is_reference(Handle) ->
  list_to_binary(ref_to_list(Handle)).

decode_handle(Bin) ->
  List = binary_to_list(Bin),
  try
    list_to_pid(List)
  catch
    error:badarg -> list_to_ref(List)
  end.
