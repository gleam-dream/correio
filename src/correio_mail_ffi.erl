-module(correio_mail_ffi).
-export([parse_mailbox/1, safe_header/1, valid_header_name/1, valid_custom_header/2, valid_content_type/1, valid_content_id/1, encode/8]).

%% The quoted-printable escape of each byte value, indexed by value + 1.
-define(ESCAPED, {
    <<"=00">>, <<"=01">>, <<"=02">>, <<"=03">>, <<"=04">>, <<"=05">>, <<"=06">>, <<"=07">>,
    <<"=08">>, <<"=09">>, <<"=0A">>, <<"=0B">>, <<"=0C">>, <<"=0D">>, <<"=0E">>, <<"=0F">>,
    <<"=10">>, <<"=11">>, <<"=12">>, <<"=13">>, <<"=14">>, <<"=15">>, <<"=16">>, <<"=17">>,
    <<"=18">>, <<"=19">>, <<"=1A">>, <<"=1B">>, <<"=1C">>, <<"=1D">>, <<"=1E">>, <<"=1F">>,
    <<"=20">>, <<"=21">>, <<"=22">>, <<"=23">>, <<"=24">>, <<"=25">>, <<"=26">>, <<"=27">>,
    <<"=28">>, <<"=29">>, <<"=2A">>, <<"=2B">>, <<"=2C">>, <<"=2D">>, <<"=2E">>, <<"=2F">>,
    <<"=30">>, <<"=31">>, <<"=32">>, <<"=33">>, <<"=34">>, <<"=35">>, <<"=36">>, <<"=37">>,
    <<"=38">>, <<"=39">>, <<"=3A">>, <<"=3B">>, <<"=3C">>, <<"=3D">>, <<"=3E">>, <<"=3F">>,
    <<"=40">>, <<"=41">>, <<"=42">>, <<"=43">>, <<"=44">>, <<"=45">>, <<"=46">>, <<"=47">>,
    <<"=48">>, <<"=49">>, <<"=4A">>, <<"=4B">>, <<"=4C">>, <<"=4D">>, <<"=4E">>, <<"=4F">>,
    <<"=50">>, <<"=51">>, <<"=52">>, <<"=53">>, <<"=54">>, <<"=55">>, <<"=56">>, <<"=57">>,
    <<"=58">>, <<"=59">>, <<"=5A">>, <<"=5B">>, <<"=5C">>, <<"=5D">>, <<"=5E">>, <<"=5F">>,
    <<"=60">>, <<"=61">>, <<"=62">>, <<"=63">>, <<"=64">>, <<"=65">>, <<"=66">>, <<"=67">>,
    <<"=68">>, <<"=69">>, <<"=6A">>, <<"=6B">>, <<"=6C">>, <<"=6D">>, <<"=6E">>, <<"=6F">>,
    <<"=70">>, <<"=71">>, <<"=72">>, <<"=73">>, <<"=74">>, <<"=75">>, <<"=76">>, <<"=77">>,
    <<"=78">>, <<"=79">>, <<"=7A">>, <<"=7B">>, <<"=7C">>, <<"=7D">>, <<"=7E">>, <<"=7F">>,
    <<"=80">>, <<"=81">>, <<"=82">>, <<"=83">>, <<"=84">>, <<"=85">>, <<"=86">>, <<"=87">>,
    <<"=88">>, <<"=89">>, <<"=8A">>, <<"=8B">>, <<"=8C">>, <<"=8D">>, <<"=8E">>, <<"=8F">>,
    <<"=90">>, <<"=91">>, <<"=92">>, <<"=93">>, <<"=94">>, <<"=95">>, <<"=96">>, <<"=97">>,
    <<"=98">>, <<"=99">>, <<"=9A">>, <<"=9B">>, <<"=9C">>, <<"=9D">>, <<"=9E">>, <<"=9F">>,
    <<"=A0">>, <<"=A1">>, <<"=A2">>, <<"=A3">>, <<"=A4">>, <<"=A5">>, <<"=A6">>, <<"=A7">>,
    <<"=A8">>, <<"=A9">>, <<"=AA">>, <<"=AB">>, <<"=AC">>, <<"=AD">>, <<"=AE">>, <<"=AF">>,
    <<"=B0">>, <<"=B1">>, <<"=B2">>, <<"=B3">>, <<"=B4">>, <<"=B5">>, <<"=B6">>, <<"=B7">>,
    <<"=B8">>, <<"=B9">>, <<"=BA">>, <<"=BB">>, <<"=BC">>, <<"=BD">>, <<"=BE">>, <<"=BF">>,
    <<"=C0">>, <<"=C1">>, <<"=C2">>, <<"=C3">>, <<"=C4">>, <<"=C5">>, <<"=C6">>, <<"=C7">>,
    <<"=C8">>, <<"=C9">>, <<"=CA">>, <<"=CB">>, <<"=CC">>, <<"=CD">>, <<"=CE">>, <<"=CF">>,
    <<"=D0">>, <<"=D1">>, <<"=D2">>, <<"=D3">>, <<"=D4">>, <<"=D5">>, <<"=D6">>, <<"=D7">>,
    <<"=D8">>, <<"=D9">>, <<"=DA">>, <<"=DB">>, <<"=DC">>, <<"=DD">>, <<"=DE">>, <<"=DF">>,
    <<"=E0">>, <<"=E1">>, <<"=E2">>, <<"=E3">>, <<"=E4">>, <<"=E5">>, <<"=E6">>, <<"=E7">>,
    <<"=E8">>, <<"=E9">>, <<"=EA">>, <<"=EB">>, <<"=EC">>, <<"=ED">>, <<"=EE">>, <<"=EF">>,
    <<"=F0">>, <<"=F1">>, <<"=F2">>, <<"=F3">>, <<"=F4">>, <<"=F5">>, <<"=F6">>, <<"=F7">>,
    <<"=F8">>, <<"=F9">>, <<"=FA">>, <<"=FB">>, <<"=FC">>, <<"=FD">>, <<"=FE">>, <<"=FF">>}).

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
%% part inside the size bound checked before encoding, and base64 otherwise.
%% Text with a carriage return outside CRLF is base64, which preserves it
%% exactly. No line break follows the content, so the part decodes to the text
%% itself. Each check reads the whole text once and the output is iodata of
%% sub-binaries or one binary per line, never a term per byte.
text_leaf(Type, Text) ->
    Lines = binary:split(Text, [<<"\r\n">>, <<"\n">>], [global]),
    {Encoding, Content} =
        case lone_carriage_return(Text) of
            true -> {<<"base64">>, base64_lines(base64:encode(Text))};
            false -> text_encoding(Text, Lines)
        end,
    [headers([{<<"Content-Type">>, Type}, {<<"Content-Transfer-Encoding">>, Encoding}]), <<"\r\n">>, Content].
text_encoding(Text, Lines) ->
    case seven_bit(Text, Lines) of
        true -> {<<"7bit">>, lists:join(<<"\r\n">>, Lines)};
        %% Each byte outside ASCII triples, so text that is more than half
        %% such bytes cannot fit and is not encoded twice.
        false ->
            case 2 * high_bytes(Text, 0) > byte_size(Text) of
                true -> {<<"base64">>, base64_lines(base64:encode(Text))};
                false ->
                    Quoted = lists:join(<<"\r\n">>, [quoted_line(L) || L <- Lines]),
                    case iolist_size(Quoted) =< 2 * byte_size(Text) of
                        true -> {<<"quoted-printable">>, Quoted};
                        false -> {<<"base64">>, base64_lines(base64:encode(Text))}
                    end
            end
    end.
lone_carriage_return(Text) ->
    binary:match(Text, <<"\r">>) =/= nomatch andalso matches(Text, <<"\r(?!\n)">>).
%% Text is safe as 7bit when every line is printable ASCII or tabs within 998
%% bytes, has no trailing white space a relay could strip, and does not start
%% with "From ", which mailbox storage rewrites. The caller has excluded a
%% carriage return outside CRLF.
seven_bit(Text, Lines) ->
    lists:all(fun(L) -> byte_size(L) =< 998 end, Lines)
        andalso not matches(Text, <<"[^\\t\\r\\n\\x20-\\x7e]">>)
        andalso binary:match(Text, [<<" \n">>, <<"\t\n">>, <<" \r\n">>, <<"\t\r\n">>]) =:= nomatch
        andalso not lists:member(binary:last(Text), [$\s, $\t])
        andalso binary:match(Text, <<"\nFrom ">>) =:= nomatch
        andalso binary:longest_common_prefix([Text, <<"From ">>]) < 5.
%% Counts bytes at or above 128, four bytes per step: the high bits of a word
%% are moved to the low bit of each byte and summed by one multiplication.
high_bytes(<<Word:32, Rest/binary>>, N) ->
    Bits = (Word band 16#80808080) bsr 7,
    high_bytes(Rest, N + (((Bits * 16#01010101) bsr 24) band 255));
high_bytes(<<C, Rest/binary>>, N) -> high_bytes(Rest, N + (C bsr 7));
high_bytes(<<>>, N) -> N.
%% RFC 2045 quoted-printable with soft breaks so no encoded line exceeds 76.
%% Runs of literal bytes are emitted as parts of the line, not byte by byte.
quoted_line(<<"F", Rest/binary>> = Line) when binary_part(Line, 0, min(5, byte_size(Line))) =:= <<"From ">> ->
    quoted(Rest, Rest, 0, 0, 3, [<<"=46">>]);
quoted_line(Line) -> quoted(Line, Line, 0, 0, 0, []).
%% Pos is the offset of the next byte in Line, Start the offset of the pending
%% literal run, and Used the length of the current encoded line.
quoted(<<>>, Line, Pos, Start, _, Acc) ->
    lists:reverse(run(Line, Start, Pos, Acc));
quoted(<<C>>, Line, Pos, Start, Used, Acc) when C =:= $\s; C =:= $\t ->
    {_, Acc1} = escaped(C, Line, Pos, Start, Used, Acc),
    lists:reverse(Acc1);
quoted(<<C, Rest/binary>>, Line, Pos, Start, Used, Acc) when C >= 33, C =< 126, C =/= $=; C =:= $\s; C =:= $\t ->
    case Used >= 75 of
        true -> quoted(Rest, Line, Pos + 1, Pos, 1, [<<"=\r\n">> | run(Line, Start, Pos, Acc)]);
        false -> quoted(Rest, Line, Pos + 1, Start, Used + 1, Acc)
    end;
quoted(<<C, Rest/binary>>, Line, Pos, Start, Used, Acc) ->
    {Used1, Acc1} = escaped(C, Line, Pos, Start, Used, Acc),
    quoted(Rest, Line, Pos + 1, Pos + 1, Used1, Acc1).
escaped(C, Line, Pos, Start, Used, Acc) when Used + 3 > 75 ->
    {3, [element(C + 1, ?ESCAPED), <<"=\r\n">> | run(Line, Start, Pos, Acc)]};
escaped(C, Line, Pos, Start, Used, Acc) ->
    {Used + 3, [element(C + 1, ?ESCAPED) | run(Line, Start, Pos, Acc)]}.
run(_, Start, Start, Acc) -> Acc;
run(Line, Start, Pos, Acc) -> [binary_part(Line, Start, Pos - Start) | Acc].
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
