-module(correio_mail_ffi).
-export([parse_mailbox/1, safe_header/1, valid_header_name/1, valid_custom_header/2, valid_content_type/1, valid_content_id/1, encode/8]).

parse_mailbox(Value) when byte_size(Value) =< 254 ->
    case binary:split(Value, <<"@">>, [global]) of
        [Local, Domain] when byte_size(Local) > 0, byte_size(Local) =< 64, byte_size(Domain) > 0 ->
            Atom = <<"[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+">>,
            Pattern = <<"\\A", Atom/binary, "(?:\\.", Atom/binary, ")*\\z">>,
            Labels = binary:split(Domain, <<".">>, [global]),
            case matches(Local, Pattern) andalso lists:all(fun valid_label/1, Labels) of
                true -> {ok, <<Local/binary, "@", (string:lowercase(Domain))/binary>>};
                false -> {error, nil}
            end;
        _ -> {error, nil}
    end;
parse_mailbox(_) -> {error, nil}.

valid_label(Label) -> byte_size(Label) =< 63 andalso matches(Label, <<"\\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\z">>).
safe_header(Value) ->
    try re:run(Value, <<"[\\p{Cc}\\p{Zl}\\p{Zp}]">>, [unicode,{capture,none}]) =:= nomatch
    catch _:_ -> false end.
valid_header_name(Value) -> byte_size(Value) =< 64 andalso matches(Value, <<"\\A[A-Za-z0-9][A-Za-z0-9-]*\\z">>).
valid_custom_header(Name,Value) -> byte_size(Name) + byte_size(Value) + 2 =< 998 andalso
    lists:all(fun(C) -> C >= 32 andalso C =< 126 end,binary_to_list(Value)).
valid_content_type(Value) -> byte_size(Value) =< 127 andalso
    not lists:member(hd(binary:split(string:lowercase(Value), <<"/">>)), [<<"message">>,<<"multipart">>]) andalso
    matches(Value, <<"\\A[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*\\z">>).
valid_content_id(Value) -> byte_size(Value) > 0 andalso byte_size(Value) =< 254 andalso matches(Value, <<"\\A[A-Za-z0-9][A-Za-z0-9@._+-]*\\z">>).
matches(Value, Pattern) -> re:run(Value, Pattern, [{capture, none}]) =:= match.

encode(From, To, Cc, Subject, Body, ReplyTo, Headers, Attachments) ->
    try
        Base = [{<<"From">>, mailbox(From)}, {<<"To">>, mailboxes(To)}]
            ++ optional_header(<<"Cc">>, Cc)
            ++ case ReplyTo of none -> []; {some, A} -> [{<<"Reply-To">>, mailbox(A)}] end
            ++ [{<<"Subject">>, encoded_words(Subject)}, {<<"MIME-Version">>, <<"1.0">>},
                {<<"Date">>, mail_date()}, {<<"Message-ID">>, [<<"<">>, unique(), <<"@correio.invalid>">>]}]
            ++ Headers,
        {Inline, Files} = lists:partition(fun({_,_,_,D}) -> element_or_atom(D) =:= inline end, Attachments),
        Content = body_with_inline(Body, Inline),
        Mixed = case Attachments of [] -> Content; _ -> multipart(<<"mixed">>, [Content | [attachment(A) || A <- Files]]) end,
        {ok, iolist_to_binary([headers(Base), Mixed])}
    catch _:_ -> {error, encoding_failed} end.

element_or_atom(T) when is_tuple(T) -> element(1,T);
element_or_atom(A) -> A.
optional_header(_, []) -> [];
optional_header(Name, Addresses) -> [{Name, mailboxes(Addresses)}].
mailboxes(Addresses) -> lists:join(<<",\r\n ">>, [mailbox(A) || A <- Addresses]).
mailbox({Email, none}) -> Email;
mailbox({Email, {some, <<>>}}) -> Email;
mailbox({Email, {some, Name}}) -> [encoded_words(Name), <<" <">>, Email, <<">">>].
headers(Pairs) -> [[N, <<": ">>, V, <<"\r\n">>] || {N,V} <- Pairs].

%% Encoded words remain below RFC 2047's 75-character maximum and split on
%% Unicode scalar boundaries. Encoding every unstructured value removes
%% ambiguity around quotes, commas, and non-ASCII display names.
encoded_words(<<>>) -> <<>>;
encoded_words(Value) ->
    Chunks = unicode_chunks(unicode:characters_to_list(Value), [], 0, []),
    lists:join(<<"\r\n ">>, [[<<"=?UTF-8?B?">>, base64:encode(C), <<"?=">>] || C <- Chunks]).
unicode_chunks([], [], _, Acc) -> lists:reverse(Acc);
unicode_chunks([], Current, _, Acc) -> lists:reverse([unicode:characters_to_binary(lists:reverse(Current)) | Acc]);
unicode_chunks([C | Rest] = All, Current, Size, Acc) ->
    Length = byte_size(unicode:characters_to_binary([C])),
    case Size + Length > 42 of
        true -> unicode_chunks(All, [], 0, [unicode:characters_to_binary(lists:reverse(Current)) | Acc]);
        false -> unicode_chunks(Rest, [C | Current], Size + Length, Acc)
    end.

body({text, Text}) -> leaf(<<"text/plain; charset=utf-8">>, [], Text);
body({html, Html}) -> leaf(<<"text/html; charset=utf-8">>, [], Html);
body({alternative, Text, Html}) -> multipart(<<"alternative">>, [body({text,Text}), body({html,Html})]).
body_with_inline(Body, []) -> body(Body);
body_with_inline({alternative, Text, Html}, Inline) ->
    multipart(<<"alternative">>, [body({text,Text}), body_with_inline({html,Html},Inline)]);
body_with_inline(Body, Inline) -> multipart(<<"related">>, [body(Body) | [attachment(A) || A <- Inline]]).
leaf(Type, Extra, Bytes) -> [headers([{<<"Content-Type">>, Type}, {<<"Content-Transfer-Encoding">>, <<"base64">>}] ++ Extra), <<"\r\n">>, base64_lines(base64:encode(Bytes)), <<"\r\n">>].
base64_lines(<<Chunk:76/binary, Rest/binary>>) -> [Chunk, <<"\r\n">>, base64_lines(Rest)];
base64_lines(Rest) -> Rest.
multipart(Subtype, Parts) ->
    Boundary = <<"correio_", (unique())/binary>>,
    [<<"Content-Type: multipart/">>, Subtype, <<"; boundary=\"">>, Boundary, <<"\"\r\n\r\n">>,
     [[<<"--">>, Boundary, <<"\r\n">>, P, <<"\r\n">>] || P <- Parts], <<"--">>, Boundary, <<"--\r\n">>].
attachment({Filename, ContentType, Bytes, Disposition}) ->
    {Kind, Extra} = case Disposition of attachment_file -> {<<"attachment">>, []}; {inline, Cid} -> {<<"inline">>, [{<<"Content-ID">>, [<<"<">>, Cid, <<">">>]}]} end,
    Params = filename_parameters(Filename),
    leaf(ContentType, [{<<"Content-Disposition">>, [Kind, Params]} | Extra], Bytes).

%% RFC 2231 parameter continuations preserve arbitrary Unicode filenames.
filename_parameters(Name) ->
    Encoded = [percent(C) || <<C>> <= Name],
    Chunks = chunks(Encoded, 15),
    case Chunks of
        [Only] -> [<<";\r\n filename*=utf-8''">>, Only];
        _ -> [[<<";\r\n filename*">>, integer_to_binary(I), <<"*=">>, case I of 0 -> <<"utf-8''">>; _ -> <<>> end, C] || {I,C} <- lists:zip(lists:seq(0,length(Chunks)-1), Chunks)]
    end.
percent(C) -> io_lib:format("%~2.16.0B", [C]).
chunks([], _) -> [];
chunks(List, N) -> {Head,Tail} = lists:split(min(N,length(List)),List), [Head | chunks(Tail,N)].
unique() -> binary:encode_hex(crypto:strong_rand_bytes(18), lowercase).
mail_date() ->
    {{Y,M,D},{H,Min,S}} = calendar:universal_time(),
    Days = {"Mon","Tue","Wed","Thu","Fri","Sat","Sun"},
    Months = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"},
    io_lib:format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B +0000", [element(calendar:day_of_the_week(Y,M,D),Days),D,element(M,Months),Y,H,Min,S]).
