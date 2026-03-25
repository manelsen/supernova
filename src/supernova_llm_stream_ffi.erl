-module(supernova_llm_stream_ffi).
-export([start_request/3, read_chunk/2, cancel_request/1]).

%% Start a streaming HTTP request.
%% Returns {ok, RequestId} or {error, Reason}.
start_request(Url, Headers, Body) ->
  try
    ReqHeaders = [{list_to_binary(K), list_to_binary(V)} || {K, V} <- Headers],
    Opts = [async, {stream_to, self()}],
    case hackney:request(post, Url, ReqHeaders, Body, Opts) of
      {ok, ClientRef} ->
        RequestId = erlang:ref_to_list(ClientRef),
        {ok, list_to_binary(RequestId)};
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
    RequestId = list_to_ref(binary_to_list(RequestIdBin)),
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
    RequestId = list_to_ref(binary_to_list(RequestIdBin)),
    hackney:close(RequestId)
  catch
    _:_ -> nil
  end,
  nil.
