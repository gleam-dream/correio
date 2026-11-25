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
            ++ [{<<"Subject">>, subject(Subject)}, {<<"MIME-Version">>, <<"1.0">>},
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
mailbox({Email, {some, Name}}) -> [display_name(Name), <<" <">>, Email, <<">">>].
headers(Pairs) -> [[N, <<": ">>, V, <<"\r\n">>] || {N,V} <- Pairs].

%% A subject of printable ASCII is emitted as written and folded before
%% spaces, so unfolding restores it exactly. A subject that could be read as
%% an encoded word, that starts or ends with a space, or that holds a word too
%% long for one line is emitted as encoded words, like any non-ASCII subject.
subject(Value) ->
    case plain_subject(Value) of
        true -> fold(re:run(Value, <<"(?:^| +)[^ ]+">>, [global, {capture, first, binary}]), 9);
        false -> encoded_words(Value)
    end.
plain_subject(Value) ->
    printable_ascii(Value) andalso binary:match(Value, <<"=?">>) =:= nomatch
        andalso matches(Value, <<"\\A[^ ](?:.*[^ ])?\\z">>)
        andalso not matches(Value, <<"[^ ]{900}">>).
fold({match, Chunks}, Used) ->
    [[First] | Rest] = Chunks,
    [First | fold_chunks([C || [C] <- Rest], Used + byte_size(First))].
fold_chunks([], _) -> [];
fold_chunks([Chunk | Rest], Used) when Used + byte_size(Chunk) > 78 ->
    [<<"\r\n">>, Chunk | fold_chunks(Rest, byte_size(Chunk))];
fold_chunks([Chunk | Rest], Used) -> [Chunk | fold_chunks(Rest, Used + byte_size(Chunk))].

%% A display name of printable ASCII that fits one line is emitted as atoms
%% when every character is atom text, and as a quoted string otherwise, with
%% quotes and backslashes escaped. Other names are emitted as encoded words.
display_name(Name) ->
    Plain = printable_ascii(Name) andalso byte_size(Name) =< 60
        andalso binary:match(Name, <<"=?">>) =:= nomatch,
    Atoms = matches(Name, <<"\\A[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?: [A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*\\z">>),
    case {Plain, Atoms} of
        {true, true} -> Name;
        {true, false} -> [$", re:replace(Name, <<"[\\\\\"]">>, <<"\\\\&">>, [global]), $"];
        {false, _} -> encoded_words(Name)
    end.
printable_ascii(Value) -> lists:all(fun(C) -> C >= 32 andalso C =< 126 end, binary_to_list(Value)).

%% Encoded words remain below RFC 2047's 75-character maximum and split on
%% Unicode scalar boundaries.
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

body({text, Text}) -> text_leaf(<<"text/plain; charset=utf-8">>, Text);
body({html, Html}) -> text_leaf(<<"text/html; charset=utf-8">>, Html);
body({alternative, Text, Html}) -> multipart(<<"alternative">>, [body({text,Text}), body({html,Html})]).
body_with_inline(Body, []) -> body(Body);
body_with_inline({alternative, Text, Html}, Inline) ->
    multipart(<<"alternative">>, [body({text,Text}), body_with_inline({html,Html},Inline)]);
body_with_inline(Body, Inline) -> multipart(<<"related">>, [body(Body) | [attachment(A) || A <- Inline]]).
%% Text line breaks (CRLF or LF) are emitted as CRLF. Text is emitted as 7bit
%% when transports carry it unchanged. Other text is quoted-printable when that
%% is at most twice the text, which holds for mostly ASCII text and keeps the
%% part inside the size bound checked before encoding, and base64 otherwise. Text with a carriage return outside CRLF is
%% base64, which preserves it exactly. No line break follows the content, so
%% the part decodes to the text itself.
text_leaf(Type, Text) ->
    Lines = binary:split(Text, [<<"\r\n">>, <<"\n">>], [global]),
    {Encoding, Content} =
        case {lists:any(fun(L) -> binary:match(L, <<"\r">>) =/= nomatch end, Lines),
              lists:all(fun seven_bit_line/1, Lines)} of
            {true, _} -> {<<"base64">>, base64_lines(base64:encode(Text))};
            {false, true} -> {<<"7bit">>, lists:join(<<"\r\n">>, Lines)};
            {false, false} ->
                %% Each byte outside ASCII triples, so text that is more than
                %% half such bytes cannot fit and is not encoded twice.
                Quoted = case 2 * length([C || <<C>> <= Text, C >= 128]) > byte_size(Text) of
                    true -> too_large;
                    false -> iolist_to_binary(lists:join(<<"\r\n">>, [quoted_line(L) || L <- Lines]))
                end,
                case is_binary(Quoted) andalso byte_size(Quoted) =< 2 * byte_size(Text) of
                    true -> {<<"quoted-printable">>, Quoted};
                    false -> {<<"base64">>, base64_lines(base64:encode(Text))}
                end
        end,
    [headers([{<<"Content-Type">>, Type}, {<<"Content-Transfer-Encoding">>, Encoding}]), <<"\r\n">>, Content].
%% A line is safe as 7bit when it is printable ASCII or tabs within 998 bytes,
%% has no trailing white space a relay could strip, and does not start with
%% "From ", which mailbox storage rewrites.
seven_bit_line(Line) ->
    byte_size(Line) =< 998
        andalso matches(Line, <<"\\A(?!From )(?:[\\t\\x20-\\x7e]*[\\x21-\\x7e])?\\z">>).
%% RFC 2045 quoted-printable with soft breaks so no encoded line exceeds 76.
quoted_line(Line) -> soft_breaks(quoted_tokens(Line, start), 0).
quoted_tokens(<<>>, _) -> [];
quoted_tokens(<<"From ", Rest/binary>>, start) -> [<<"=46">> | quoted_tokens(<<"rom ", Rest/binary>>, middle)];
quoted_tokens(<<C>>, _) when C =:= $\s; C =:= $\t -> [escape(C)];
quoted_tokens(<<C, Rest/binary>>, _) when C =:= $\s; C =:= $\t; C >= 33, C =< 126, C =/= $= -> [<<C>> | quoted_tokens(Rest, middle)];
quoted_tokens(<<C, Rest/binary>>, _) -> [escape(C) | quoted_tokens(Rest, middle)].
escape(C) -> <<$=, (hex(C bsr 4)), (hex(C band 15))>>.
hex(N) when N < 10 -> $0 + N;
hex(N) -> $A + N - 10.
soft_breaks([], _) -> [];
soft_breaks([Token | Rest], Used) when Used + byte_size(Token) > 75 -> [<<"=\r\n">>, Token | soft_breaks(Rest, byte_size(Token))];
soft_breaks([Token | Rest], Used) -> [Token | soft_breaks(Rest, Used + byte_size(Token))].
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
