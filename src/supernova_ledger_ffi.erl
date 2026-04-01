-module(supernova_ledger_ffi).
-export([current_timestamp/0, write_audit/4, format_float/1, sleep_ms/1]).

current_timestamp() ->
  erlang:system_time(millisecond).

format_float(F) ->
  % Use io_lib:format with ~f to get decimal representation,
  % then strip trailing zeros and decimal point if unnecessary
  Raw = io_lib:format("~f", [F]),
  Stripped = lists:reverse(drop_trailing_zeros(lists:reverse(Raw))),
  % Ensure we have at least one digit after decimal if decimal point present
  case Stripped of
    [$., C | Rest] when C =:= $0 -> list_to_binary([C, Rest]);
    _ -> list_to_binary(Stripped)
  end.

drop_trailing_zeros([$0 | Rest]) -> drop_trailing_zeros(Rest);
drop_trailing_zeros([$. | _]) -> [];
drop_trailing_zeros(Other) -> Other.

write_audit(AgentId, Resource, Amount, Timestamp) ->
  % For now, just log to stdout. In production, this would write to a proper audit log.
  io:format("AUDIT: agent=~s resource=~s amount=~p timestamp=~p~n",
            [AgentId, Resource, Amount, Timestamp]),
  {ok, nil}.
sleep_ms(Ms) ->
    timer:sleep(Ms),
    nil.
