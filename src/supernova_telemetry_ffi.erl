-module(supernova_telemetry_ffi).
-export([write_event/3]).

write_event(Name, Timestamp, AgentId) ->
  % For now, just log to stdout. In production, this would feed into the ledger.
  io:format("TELEMETRY: event=~s ts=~p agent=~s~n",
            [Name, Timestamp, AgentId]),
  {ok, nil}.
