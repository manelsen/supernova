-module(supernova_text_ffi).
-export([fold/1]).

%% Text for matching: case folded and without accents ("Ação" -> "acao").
%% Decomposes (NFD), drops the combining marks U+0300..U+036F, then folds
%% case. Text that is not valid UTF-8 comes back unchanged: string:casefold
%% raises badarg on it.
fold(Text) ->
    case unicode:characters_to_nfd_binary(Text) of
        Nfd when is_binary(Nfd) ->
            Stripped = << <<C/utf8>> || <<C/utf8>> <= Nfd,
                                        not (C >= 16#300 andalso C =< 16#36F) >>,
            string:casefold(Stripped);
        _ ->
            Text
    end.
