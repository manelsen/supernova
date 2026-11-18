-module(supernova_mock_ffi).
-export([ensure_hackney/0, clear_prompts/0, record_prompt/1, prompts/0, sim_http/5, network_fail_once/1, clock_set/1, clock_now/0]).

%% Return true exactly once per key in the calling process. Used by the mock
%% provider to simulate a network failure followed by a successful retry.
clock_set(Timestamp) ->
    persistent_term:put({supernova_mock_clock}, Timestamp).

clock_now() ->
    persistent_term:get({supernova_mock_clock}, 0).

network_fail_once(Key) ->
    case get({mock_network_fail_once, Key}) of
        undefined ->
            put({mock_network_fail_once, Key}, true),
            true;
        _ -> false
    end.

ensure_hackney() -> application:ensure_all_started(hackney).

sim_http(Method, Port, Path, Token, Body) ->
    Url = lists:concat(["http://127.0.0.1:", Port, binary_to_list(Path)]),
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Token)},
               {"content-type", "application/json"}],
    Request = {Url, Headers, "application/json", Body},
    _ = application:ensure_all_started(inets),
    case httpc:request(binary_to_atom(Method, utf8), Request, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, ResponseBody}} -> {Status, ResponseBody};
        {error, _} -> {0, <<>>}
    end.

clear_prompts() ->
    persistent_term:put({supernova, mock_prompts}, []).

record_prompt(Prompt) ->
    Existing = persistent_term:get({supernova, mock_prompts}, []),
    persistent_term:put({supernova, mock_prompts}, [Prompt | Existing]),
    ok.

prompts() ->
    persistent_term:get({supernova, mock_prompts}, []).
