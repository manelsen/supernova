-module(supernova_mcp_computer_ffi).
-export([person_hash/1, unique_id/0]).

%% The name of a person's folder in the computer (PRD-S, S19): the first 16
%% hex characters of the SHA-256 of the agent id. Nothing of the channel or
%% the person's id shows in the path.
person_hash(AgentId) ->
    Digest = crypto:hash(sha256, AgentId),
    string:lowercase(binary:part(binary:encode_hex(Digest), 0, 16)).

%% A positive integer, unique in this node: JSON-RPC request ids.
unique_id() ->
    erlang:unique_integer([positive, monotonic]).
