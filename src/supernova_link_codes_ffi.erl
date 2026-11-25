%% In-memory store for link codes and failed tries (PRD-I, I-02). Codes
%% live ten minutes; a restart forgets them, which is fine.
-module(supernova_link_codes_ffi).
-export([put/2, get/1, delete/1, random_code/0]).

-define(TABLE, supernova_link_codes).

table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            Self = self(),
            Pid = spawn(fun() ->
                try ets:new(?TABLE, [named_table, public, set]) of
                    _ -> ok
                catch error:badarg -> ok
                end,
                Self ! {link_codes_ready, self()},
                receive stop -> ok end
            end),
            receive {link_codes_ready, Pid} -> ok after 1000 -> ok end,
            ?TABLE;
        _ -> ?TABLE
    end.

put(Key, Value) ->
    ets:insert(table(), {Key, Value}),
    nil.

get(Key) ->
    case ets:lookup(table(), Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, nil}
    end.

delete(Key) ->
    ets:delete(table(), Key),
    nil.

%% Six characters with no 0/O or 1/I.
random_code() ->
    Alphabet = <<"ABCDEFGHJKLMNPQRSTUVWXYZ23456789">>,
    << <<(binary:at(Alphabet, B rem 32))>> || <<B>> <= crypto:strong_rand_bytes(6) >>.
