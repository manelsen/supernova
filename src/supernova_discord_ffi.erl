-module(supernova_discord_ffi).
-export([encode_json/1]).

%% Encodes back to text a term that `gleam/json` decoded (OTP `json`), so
%% the `d` of a gateway frame reaches `discord_events` as the JSON it was.
encode_json(Term) ->
    iolist_to_binary(json:encode(Term)).
