-module(k_i3_ffi).
-export([files_containing/2]).

%% Every regular file under Dir whose bytes contain Needle (PRD-K, K-I3).
files_containing(Dir, Needle) ->
    filelib:fold_files(binary_to_list(Dir), ".*", true,
        fun(Path, Acc) ->
            case file:read_file(Path) of
                {ok, Bytes} ->
                    case binary:match(Bytes, Needle) of
                        nomatch -> Acc;
                        _ -> [list_to_binary(Path) | Acc]
                    end;
                _ -> Acc
            end
        end, []).
