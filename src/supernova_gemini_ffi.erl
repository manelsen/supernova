%% HTTP for supernova/llm/gemini_media (PRD-A, A-03), ported from Amélie's
%% Gemini adapter: the key goes in a header, never in the URL; large files
%% go up in 8 MiB parts (resumable upload), read from disk piece by piece.
-module(supernova_gemini_ffi).
-export([request/5, upload_resumable/5]).

%% Used only when the API does not announce its granularity.
-define(PART, 8388608).

opts(Url) ->
    Base = [{timeout, 600000}, {connect_timeout, 10000}, {autoredirect, false}],
    case uri_string:parse(binary_to_list(Url)) of
        #{scheme := "https", host := Host} ->
            [{ssl, [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
                    {server_name_indication, Host},
                    {customize_hostname_check,
                     [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}
             | Base];
        _ -> Base
    end.

start() ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    ok.

%% Method is get | post | delete. Returns {ok, {Status, Body}} | {error, Reason}.
request(Method, Url, ApiKey, ContentType, Body) ->
    start(),
    Headers = [{"x-goog-api-key", binary_to_list(ApiKey)}],
    Req = case Method of
        post -> {binary_to_list(Url), Headers, binary_to_list(ContentType), Body};
        _ -> {binary_to_list(Url), Headers}
    end,
    case httpc:request(Method, Req, opts(Url), [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, RespBody}} -> {ok, {Status, RespBody}};
        {error, Reason} -> {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Upload a file to the Files API. StartUrl is <base>/upload/v1beta/files.
%% Returns {ok, Body} with the final JSON ({"file": {...}}).
upload_resumable(StartUrl, ApiKey, Path, Mime, Size) ->
    start(),
    Key = binary_to_list(ApiKey),
    Headers = [{"x-goog-api-key", Key},
               {"x-goog-upload-protocol", "resumable"},
               {"x-goog-upload-command", "start"},
               {"x-goog-upload-header-content-length", integer_to_list(Size)},
               {"x-goog-upload-header-content-type", binary_to_list(Mime)}],
    Meta = <<"{\"file\":{\"display_name\":\"supernova-media\"}}">>,
    case httpc:request(post, {binary_to_list(StartUrl), Headers, "application/json", Meta},
                       opts(StartUrl), [{body_format, binary}]) of
        {ok, {{_, 200, _}, RespHeaders, _}} ->
            case proplists:get_value("x-goog-upload-url", RespHeaders) of
                undefined -> {error, <<"no upload url">>};
                UploadUrl0 ->
                  case same_origin(StartUrl, list_to_binary(UploadUrl0)) of
                    false -> {error, <<"upload url outside the Gemini API">>};
                    true ->
                    UploadUrl = UploadUrl0,
                    %% The API announces the part size (8 MiB when the
                    %% fixtures were recorded); a part of another size is
                    %% refused with 400.
                    Part = case proplists:get_value("x-goog-upload-chunk-granularity", RespHeaders) of
                        undefined -> ?PART;
                        G -> list_to_integer(G)
                    end,
                    case file:open(Path, [read, binary, raw]) of
                        {ok, Fd} ->
                            Result = send_parts(Fd, list_to_binary(UploadUrl), Key, 0, Size, Part),
                            _ = file:close(Fd),
                            Result;
                        {error, Reason} -> {error, atom_to_binary(Reason)}
                    end
                  end
            end;
        {ok, {{_, Status, _}, _, Body}} ->
            {error, iolist_to_binary(["upload start status ", integer_to_list(Status), ": ", Body])};
        {error, Reason} -> {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% The key only follows an upload URL on the same scheme, host and port.
same_origin(A, B) ->
    Origin = fun(Url) ->
        case uri_string:parse(binary_to_list(Url)) of
            #{scheme := S, host := H} = U -> {S, H, maps:get(port, U, default)};
            _ -> invalid
        end
    end,
    OA = Origin(A),
    OA =/= invalid andalso OA =:= Origin(B).

send_parts(Fd, UploadUrl, Key, Offset, Size, Part) ->
    Chunk = case file:read(Fd, Part) of
        {ok, Bytes} -> Bytes;
        eof -> <<>>
    end,
    Last = Offset + byte_size(Chunk) >= Size,
    Command = case Last of true -> "upload, finalize"; false -> "upload" end,
    Headers = [{"x-goog-api-key", Key},
               {"x-goog-upload-offset", integer_to_list(Offset)},
               {"x-goog-upload-command", Command}],
    case httpc:request(post, {binary_to_list(UploadUrl), Headers, "application/octet-stream", Chunk},
                       opts(UploadUrl), [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} when Last -> {ok, Body};
        {ok, {{_, 200, _}, _, _}} ->
            send_parts(Fd, UploadUrl, Key, Offset + byte_size(Chunk), Size, Part);
        {ok, {{_, Status, _}, _, Body}} ->
            {error, iolist_to_binary(["upload status ", integer_to_list(Status), ": ", Body])};
        {error, Reason} -> {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.
