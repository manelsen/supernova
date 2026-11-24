%% Bench: buscar_conversa against grep, over seeded histories.
%%
%% No LLM. A person's history is seeded with filler messages and a few
%% planted facts. Each fact comes with the question an agent would later have
%% to answer, and with the query an agent would plausibly write for each
%% tool. A query "finds" the fact when the answer token is in what the tool
%% returned.
%%
%% Tools:
%%   nossa        buscar_conversa.execute_for, the real tool (one call; it
%%                has no paging).
%%   grepmem      a port of GrepMem's grep_history (agents/common.py):
%%                Python-re-like caseless regex, per line, oldest first,
%%                max_matches 10, context 1 line inside the same entry,
%%                line clip 300, ~6000 chars per call, offset paging. Each
%%                message is one entry. The agent pages until it sees the
%%                answer or 5 calls; the "esperta" agent asks for 30 per
%%                page (GrepMem's maximum).
%%   grep         GNU grep -i -E -C2 over a transcript (one line per
%%                message), first 6000 bytes, one call.
%% Regex tools run twice: "ingenua" (the agent's words turned into a regex
%% as typed) and "esperta" (accent classes, alternation).
%%
%% Run: erl -pa build/dev/erlang/*/ebin -noshell -s busca_bench main -s init stop
-module(busca_bench).
-export([main/0, main/1, serve/0]).

-define(PRINCIPAL, <<"sim:ana">>).
-define(PAGE_CALLS, 5).

main() -> main([]).

main(Args) ->
    Root = case Args of
        [R | _] -> atom_to_list(R);
        [] -> "/tmp/busca_bench"
    end,
    Sizes = [2000, 20000, 100000],
    Quality = 20000,
    io:format("# buscar_conversa x grep~n~n"),
    lists:foreach(
        fun(Size) ->
            Dir = Root ++ "/" ++ integer_to_list(Size),
            os:cmd("rm -rf " ++ Dir),
            Hist = seed(Dir, Size),
            case Size of
                Quality -> quality(Dir, Hist);
                _ -> ok
            end,
            latency(Dir, Size)
        end,
        Sizes),
    os:cmd("rm -rf " ++ Root),
    ok.

%% ---------------------------------------------------------------- facts

%% {Id, Family, File, Position (0..1), Messages, Answer, Terms, Naive, Skilled}
facts() ->
    [
     {"A", "termo raro, resposta 2 msgs depois", "priv", 0.30,
      [{user, "Lembra do cardiologista que a Bia indicou? Vou marcar com ele."},
       {assistant, "Lembro que você comentou. Qual é o nome dele?"},
       {user, "É o Dr. Valdomiro Teles, atende na Clínica Aurora."}],
      "Valdomiro", "cardiologista", "cardiologista", "cardiologista"},
     {"B", "consulta sem acento", "priv", 0.50,
      [{user, "Anota aí: o remédio da pressão agora é Losartana 50, um de manhã."},
       {assistant, "Anotado: Losartana 50 mg pela manhã."}],
      "Losartana", "remedio pressao", "remedio.*pressao",
      "rem[eé]dio.*press[aã]o"},
     {"C", "palavras em outra ordem", "g1", 0.60,
      [{user, "A senha do wifi da casa da praia mudou, agora é maresia2024."}],
      "maresia2024", "praia senha", "praia.*senha",
      "praia.*senha|senha.*praia"},
     {"D1", "termo comum, fato antigo", "priv", 0.05,
      [{user, "Consulta com o médico do joelho ficou pro dia 14, às 9h20."}],
      "9h20", "consulta medico", "consulta.*médico",
      "consulta.*m[eé]dico|m[eé]dico.*consulta"},
     {"D2", "termo comum, fato recente", "priv", 0.9995,
      [{user, "Consulta com o médico da tireoide ficou pra sexta, 16h45."}],
      "16h45", "consulta medico", "consulta.*médico",
      "consulta.*m[eé]dico|m[eé]dico.*consulta"},
     {"E", "plural irregular (sessões)", "g2", 0.40,
      [{user, "As sessões de fisioterapia vão ser com a Marília Prado."}],
      "Marília", "sessao fisioterapia", "sessão.*fisioterapia",
      "sess.*fisioterapia"},
     {"F", "sinônimo (pediatra x médico)", "priv", 0.70,
      [{user, "O pediatra do Pedro é o Dr. Anselmo, no Hospital Santa Clara."}],
      "Anselmo", "medico Pedro", "médico.*Pedro",
      "(m[eé]dico|pediatra).*Pedro"},
     {"G", "número exato", "g3", 0.20,
      [{user, "O protocolo da reclamação na operadora é 2024-118-7736."}],
      "7736", "protocolo operadora", "protocolo.*operadora",
      "protocolo.*operadora"},
     {"H", "consulta sem acento, nome próprio", "g1", 0.80,
      [{user, "Aniversário da Dona Cecília é dia 3 de março, não esquece."}],
      "3 de março", "aniversario cecilia", "aniversario.*cecilia",
      "anivers[aá]rio.*cec[ií]lia"},
     {"I", "pergunta numa msg, resposta 2 depois", "priv", 0.85,
      [{user, "Qual era mesmo o endereço da festa do Rafa? Vou te passar."},
       {assistant, "Você ainda não tinha me dito."},
       {user, "Rua Itapicuru, 418, casa 2."}],
      "Itapicuru", "endereco festa Rafa", "endereço.*festa",
      "endere[cç]o.*festa"}
    ].

%% ---------------------------------------------------------------- filler

user_templates() ->
    ["Bom dia! Hoje vou ~a.",
     "Tenho consulta com o médico ~d, me lembra?",
     "Esqueci de tomar o remédio ontem.",
     "A pressão no trabalho tá grande essa semana.",
     "Reunião às ~hh amanhã, depois te conto.",
     "Comprei ~c no mercado.",
     "O ~n mandou mensagem no grupo.",
     "Vou ligar pro médico pra remarcar a consulta.",
     "Choveu muito aqui em ~l.",
     "Me ajuda a escrever uma mensagem pro ~n?",
     "Qual era o nome daquele filme que vimos?",
     "Preciso trocar a senha do banco.",
     "A festa de aniversário do ~n foi ótima.",
     "Fui na praia no fim de semana com o ~n.",
     "Tô cansada, dormi mal.",
     "Lembra de me avisar da reunião de ~d.",
     "O ~n perguntou do endereço novo.",
     "Hoje a consulta foi rápida."].

assistant_templates() ->
    ["Claro! Posso ajudar com isso.",
     "Anotado. Quer que eu te lembre ~d?",
     "Que bom! Como foi?",
     "Entendi. Vou guardar isso.",
     "Lembre de levar os exames na consulta com o médico.",
     "Boa! O ~n vai gostar.",
     "Pode deixar, te aviso às ~hh.",
     "Sinto muito. Quer conversar sobre isso?",
     "Combinado.",
     "Faz sentido. E o ~n, o que achou?"].

slot($a) -> pick(["caminhar", "cozinhar", "ler", "arrumar a casa", "estudar"]);
slot($d) -> pick(["segunda", "terça", "quarta", "quinta", "sexta", "amanhã"]);
slot($h) -> integer_to_list(8 + rand:uniform(10));
slot($c) -> pick(["pão", "frutas", "arroz", "café", "queijo", "verduras"]);
slot($n) -> pick(["Bruno", "Carla", "Diego", "Elisa", "Fábio", "Gabi",
                  "Hugo", "Íris", "João", "Lara", "Mário"]);
slot($l) -> pick(["Niterói", "Campinas", "Recife", "Curitiba", "Belém"]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

fill(Template) -> fill(Template, []).
fill([], Acc) -> lists:reverse(Acc);
fill([$~, C | Rest], Acc) -> fill(Rest, lists:reverse(slot(C), Acc));
fill([C | Rest], Acc) -> fill(Rest, [C | Acc]).

%% ---------------------------------------------------------------- seeding

files() -> ["priv", "g1", "g2", "g3"].

%% Writes the conversations under Dir (the data dir) and returns the merged
%% history as [{At, File, Role, Text}], oldest first.
seed(Dir, Size) ->
    rand:seed(exsss, {7, 11, 13}),
    Start = 1767225600000,  % 2026-01-01
    Step = 300000,          % 5 min between messages
    Fillers = [filler(I) || I <- lists:seq(1, Size)],
    Planted = lists:foldl(
        fun({_, _, File, Pos, Msgs, _, _, _, _}, Acc) ->
            At = trunc(Pos * Size),
            {Before, After} = lists:split(At, Acc),
            Before ++ [{File, R, T} || {R, T} <- Msgs] ++ After
        end,
        Fillers, facts()),
    Timed = lists:zipwith(
        fun(I, {File, Role, Text}) -> {Start + I * Step, File, Role, Text} end,
        lists:seq(0, length(Planted) - 1), Planted),
    ConvDir = binary_to_list(
        'supernova@core@session@history_store':dir(list_to_binary(Dir),
                                                   ?PRINCIPAL)),
    ok = filelib:ensure_path(ConvDir),
    ok = filelib:ensure_path(Dir ++ "/transcript"),
    lists:foreach(
        fun(F) ->
            Mine = [M || M = {_, File, _, _} <- Timed, File =:= F],
            Json = [[json:encode(#{<<"role">> => atom_to_binary(R),
                                    <<"content">> => unicode:characters_to_binary(T),
                                    <<"at">> => At}), $\n]
                    || {At, _, R, T} <- Mine],
            ok = file:write_file(ConvDir ++ "/" ++ F ++ ".jsonl", Json),
            Txt = [[line_header(At, R), unicode:characters_to_binary(T), $\n]
                   || {At, _, R, T} <- Mine],
            ok = file:write_file(Dir ++ "/transcript/" ++ F ++ ".txt", Txt)
        end,
        files()),
    Timed.

filler(I) ->
    File = case rand:uniform(10) of
        N when N =< 4 -> "priv";
        5 -> "g1"; 6 -> "g1";
        7 -> "g2"; 8 -> "g2";
        _ -> "g3"
    end,
    case I rem 2 of
        1 -> {File, user, fill(pick(user_templates()))};
        0 -> {File, assistant, fill(pick(assistant_templates()))}
    end.

line_header(At, Role) ->
    Who = case Role of user -> "pessoa"; assistant -> "você" end,
    unicode:characters_to_binary(io_lib:format("[~s] ~ts: ", [stamp(At), Who])).

stamp(Ms) ->
    {{Y, Mo, D}, {H, Mi, _}} =
        calendar:system_time_to_universal_time(Ms, millisecond),
    io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B", [Y, Mo, D, H, Mi]).

%% ---------------------------------------------------------------- tools

nossa(Dir, Terms) ->
    Args = json:encode(#{<<"terms">> => unicode:characters_to_binary(Terms)}),
    case 'supernova@tools@buscar_conversa':execute_for(
           list_to_binary(Dir), ?PRINCIPAL, 0, iolist_to_binary(Args)) of
        {ok, Out} -> Out;
        {error, E} -> E
    end.

%% GrepMem's _grep: entries are messages, oldest first across files.
grepmem_entries(Dir) ->
    Lines = lists:append(
        [begin
             {ok, B} = file:read_file(Dir ++ "/transcript/" ++ F ++ ".txt"),
             binary:split(B, <<"\n">>, [global, trim_all])
         end || F <- files()]),
    %% sort by the stamp at the start of the line (same format, sortable)
    Sorted = lists:sort(Lines),
    [split_entry(L) || L <- Sorted].

split_entry(Line) ->
    %% header "[stamp] who:" ; body = the text
    [Head, Body] = binary:split(Line, <<": ">>),
    {Head, Body}.

grepmem(Entries, Pattern, Offset) -> grepmem(Entries, Pattern, Offset, 10).

grepmem(Entries, Pattern, Offset, Max) ->
    {ok, Rx} = re:compile(unicode:characters_to_binary(Pattern),
                          [caseless, unicode, ucp]),
    Hits = [{I, J, L}
            || {I, {_, Body}} <- lists:zip(lists:seq(1, length(Entries)), Entries),
               {J, L} <- lists:zip(lists:seq(1, length(body_lines(Body))),
                                   body_lines(Body)),
               re:run(L, Rx, [{capture, none}]) =:= match],
    Total = length(Hits),
    NEntries = length(lists:usort([I || {I, _, _} <- Hits])),
    Summary = io_lib:format("~B matching line(s) in ~B history entries.~n",
                            [Total, NEntries]),
    case Total of
        0 -> {iolist_to_binary(io_lib:format("No matches for /~ts/.",
                                             [Pattern])), Total, Total};
        _ when Offset >= Total -> {<<"No matches at offset.">>, Total, Total};
        _ ->
            Page = lists:sublist(Hits, Offset + 1, Max),
            {Body, Shown} = render_page(Entries, Page, iolist_to_binary(Summary)),
            End = Offset + Shown,
            Footer = case End < Total of
                true -> io_lib:format("(showing matches ~B-~B of ~B; call again with offset=~B for more)",
                                      [Offset + 1, End, Total, End]);
                false -> io_lib:format("(showing matches ~B-~B of ~B)",
                                       [Offset + 1, End, Total])
            end,
            {iolist_to_binary([Body, Footer]), Total, End}
    end.

body_lines(Body) -> binary:split(Body, <<"\n">>, [global]).

%% Context 1 line inside the same entry; one-line messages have none.
render_page(Entries, Page, Acc0) ->
    lists:foldl(
        fun({I, J, L}, {Acc, N}) ->
                {Head, _} = lists:nth(I, Entries),
                Piece = iolist_to_binary(
                          ["== ", Head, "\n  ", integer_to_list(J), ": ",
                           clip(L), "\n"]),
                case byte_size(Acc) + byte_size(Piece) > 6000 of
                    true -> {Acc, N};
                    false -> {<<Acc/binary, Piece/binary>>, N + 1}
                end
        end,
        {Acc0, 0}, Page).

clip(L) when byte_size(L) > 300 -> binary:part(L, 0, 300);
clip(L) -> L.

grepmem_agent(Entries, Pattern, Answer, Max) ->
    grepmem_agent(Entries, Pattern, Answer, Max, 0, 1, 0).
grepmem_agent(Entries, Pattern, Answer, Max, Offset, Call, Chars) ->
    {Out, Total, End} = grepmem(Entries, Pattern, Offset, Max),
    Chars1 = Chars + byte_size(Out),
    case found(Out, Answer) of
        true -> {true, Call, Chars1};
        false when End < Total, Call < ?PAGE_CALLS ->
            grepmem_agent(Entries, Pattern, Answer, Max, End, Call + 1, Chars1);
        false -> {false, Call, Chars1}
    end.

gnu_grep(Dir, Pattern) ->
    Grep = os:find_executable("grep"),
    Port = open_port({spawn_executable, Grep},
                     [{args, ["-r", "-h", "-a", "-i", "-E", "-C2", "-e",
                              unicode:characters_to_binary(Pattern),
                              Dir ++ "/transcript"]},
                      {env, [{"LC_ALL", "C.UTF-8"}]},
                      binary, exit_status, stream]),
    Out = collect(Port, <<>>),
    binary:part(Out, 0, min(6000, byte_size(Out))).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, _}} -> Acc
    end.

found(Out, Answer) ->
    binary:match(Out, unicode:characters_to_binary(Answer)) =/= nomatch.

%% ---------------------------------------------------------------- quality

quality(Dir, _Hist) ->
    Entries = grepmem_entries(Dir),
    io:format("## Acerto (20.000 mensagens)~n~n"),
    io:format("| Fato | Caso | nossa | grepmem ingênua | grepmem esperta | grep -C2 ingênua | grep -C2 esperta |~n"),
    io:format("|---|---|---|---|---|---|---|~n"),
    Rows = [row(Dir, Entries, F) || F <- facts()],
    Score = fun(K) -> length([x || R <- Rows, element(K, R)]) end,
    io:format("| **total** | | **~B/~B** | **~B** | **~B** | **~B** | **~B** |~n~n",
              [Score(1), length(Rows), Score(2), Score(3), Score(4), Score(5)]).

row(Dir, Entries, {Id, Family, _, _, _, Answer, Terms, Naive, Skilled}) ->
    N = nossa(Dir, Terms),
    NHit = found(N, Answer),
    {G1, C1, B1} = grepmem_agent(Entries, Naive, Answer, 10),
    {G2, C2, B2} = grepmem_agent(Entries, Skilled, Answer, 30),
    U1 = gnu_grep(Dir, Naive),
    U2 = gnu_grep(Dir, Skilled),
    io:format("| ~s | ~ts | ~ts | ~ts | ~ts | ~ts | ~ts |~n",
              [Id, Family,
               cell(NHit, 1, byte_size(N)),
               cell(G1, C1, B1), cell(G2, C2, B2),
               cell(found(U1, Answer), 1, byte_size(U1)),
               cell(found(U2, Answer), 1, byte_size(U2))]),
    {NHit, G1, G2, found(U1, Answer), found(U2, Answer)}.

cell(Hit, Calls, Bytes) ->
    Mark = case Hit of true -> "✅"; false -> "❌" end,
    CallsTxt = case Calls of 1 -> ""; _ -> io_lib:format(" ~B chamadas,", [Calls]) end,
    unicode:characters_to_binary(
      io_lib:format("~ts~ts ~B c", [Mark, CallsTxt, Bytes])).

%% ---------------------------------------------------------------- latency

latency(Dir, Size) ->
    io:format("## Latência, ~B mensagens (mediana de 7, ms)~n~n", [Size]),
    io:format("| Consulta | nossa | grepmem (lê e busca) | grep -C2 |~n|---|---|---|---|~n"),
    lists:foreach(
        fun({Label, Terms, Rx}) ->
            T1 = median(fun() -> nossa(Dir, Terms) end),
            T2 = median(fun() -> grepmem(grepmem_entries(Dir), Rx, 0) end),
            T3 = median(fun() -> gnu_grep(Dir, Rx) end),
            io:format("| ~ts | ~.1f | ~.1f | ~.1f |~n", [Label, T1, T2, T3])
        end,
        [{"rara (cardiologista)", "cardiologista", "cardiologista"},
         {"comum (consulta médico)", "consulta medico",
          "consulta.*m[eé]dico|m[eé]dico.*consulta"}]),
    io:format("~n").

median(Fun) ->
    Ts = lists:sort([element(1, timer:tc(Fun)) || _ <- lists:seq(1, 7)]),
    lists:nth(4, Ts) / 1000.

%% ---------------------------------------------------------------- server
%% For the LLM bench: one JSON object per line on stdin,
%% {"dir": DataDir, "terms": Terms}, answers {"out": Text} per line.
serve() ->
    {ok, _} = application:ensure_all_started(hackney),
    ok = io:setopts(standard_io, [{encoding, unicode}, binary]),
    serve_loop().

serve_loop() ->
    case io:get_line(standard_io, "") of
        eof -> ok;
        {error, _} -> ok;
        Line ->
            Req = json:decode(string:trim(unicode:characters_to_binary(Line))),
            Reply = case maps:get(<<"op">>, Req, <<"buscar">>) of
                <<"buscar">> -> #{<<"out">> => buscar(Req)};
                <<"gate">> -> gate(Req);
                <<"lembrar">> -> lembrar(Req)
            end,
            io:put_chars(standard_io, [json:encode(Reply), $\n]),
            serve_loop()
    end.

buscar(Req) ->
    case 'supernova@tools@buscar_conversa':execute_for(
           maps:get(<<"dir">>, Req), <<"sim:marta">>,
           maps:get(<<"offset">>, Req, -180),
           iolist_to_binary(json:encode(#{<<"terms">> => maps:get(<<"terms">>, Req)}))) of
        {ok, O} -> O;
        {error, E} -> E
    end.

%% The memory's real settings (supernova/memory/runtime.Settings): the real
%% transport, the provider asked for ("perplexity" by default), its
%% cutoffs, and no ledger.
settings(Req) ->
    Provider = case maps:get(<<"provider">>, Req, <<"perplexity">>) of
                   <<"gemini">> -> gemini;
                   _ -> perplexity
               end,
    {settings,
     'supernova@memory@decision':hackney_transport(),
     'supernova@memory@decision':endpoint(Provider, maps:get(<<"key">>, Req)),
     'supernova@memory@runtime':default_thresholds(Provider),
     2000, 15000,
     fun(_, _) -> {ok, fun(_, _) -> nil end} end}.

gate(Req) ->
    case 'supernova@memory@gate':ask(settings(Req), maps:get(<<"message">>, Req)) of
        {fired, P} -> #{<<"verdict">> => <<"fired">>, <<"p">> => P};
        {quiet, P} -> #{<<"verdict">> => <<"quiet">>, <<"p">> => P};
        skipped -> #{<<"verdict">> => <<"skipped">>};
        over_budget -> #{<<"verdict">> => <<"over_budget">>};
        {failed, E} -> #{<<"verdict">> => <<"failed">>,
                         <<"error">> => 'supernova@memory@decision':error_summary(E)}
    end.

lembrar(Req) ->
    {outcome, Text, Probability, Band, Shortlist, Tokens, Embedded, Cost, Failure} =
        'supernova@memory@recall':recall(settings(Req), maps:get(<<"dir">>, Req),
                                         <<"sim:marta">>, -180,
                                         maps:get(<<"subject">>, Req)),
    #{<<"out">> => Text,
      <<"p">> => case Probability of {some, P} -> P; none -> null end,
      <<"lista">> => Shortlist,
      <<"band">> => Band,
      <<"decision_tokens">> => Tokens,
      <<"embed_tokens">> => Embedded,
      <<"cost_microusd">> => Cost,
      <<"failure">> => case Failure of
                           {some, E} -> 'supernova@memory@decision':error_summary(E);
                           none -> null
                       end}.
