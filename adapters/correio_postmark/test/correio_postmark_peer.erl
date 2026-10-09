-module(correio_postmark_peer).
-export([start/1,report/1,now_ms/0,pause/1]).
now_ms() -> erlang:monotonic_time(millisecond).
pause(Milliseconds) -> receive after Milliseconds -> nil end.
start(Mode) ->
    {ok,L}=gen_tcp:listen(0,[binary,{active,false},{packet,line},{reuseaddr,true},{ip,{127,0,0,1}}]),
    {ok,{_,Port}}=inet:sockname(L), Parent=self(),Ref=make_ref(),
    Pid=spawn(fun() ->
        put(head,[]),put(body,<<>>),
        try
            {ok,S}=gen_tcp:accept(L,5000),gen_tcp:close(L),
            case Mode of
                close_on_accept -> gen_tcp:close(S);
                _ ->
                    Head=headers(S,[]),put(head,Head),
                    Length=length_header(Head),inet:setopts(S,[{packet,raw}]),
                    Body=case Length of 0 -> <<>>; _ -> {ok,B}=gen_tcp:recv(S,Length,3000),B end,
                    put(body,Body),respond(S,Mode)
            end
        catch _:_ -> ok
        after gen_tcp:close(L),Parent!{Ref,iolist_to_binary(get(head)),get(body)} end
    end),
    {Port,{Pid,Ref,L}}.
headers(S,Acc) ->
    case gen_tcp:recv(S,0,3000) of
        {ok,<<"\r\n">>} -> lists:reverse([<<"\r\n">>|Acc]);
        {ok,Line} -> headers(S,[Line|Acc]);
        _ -> error(closed)
    end.
length_header(Head) ->
    case [string:trim(V) || H <- Head, [K,V] <- [binary:split(H,<<":">>)], string:lowercase(K)=:= <<"content-length">>] of
        [Value] -> binary_to_integer(Value);
        _ -> 0
    end.
respond(S,{reply,Status,Body}) ->
    gen_tcp:send(S,[<<"HTTP/1.1 ">>,integer_to_binary(Status),<<" Test\r\nContent-Type: application/json\r\nContent-Length: ">>,integer_to_binary(byte_size(Body)),<<"\r\nConnection: close\r\n\r\n">>,Body]),gen_tcp:close(S);
respond(S,close_after_request) -> gen_tcp:close(S);
respond(S,stall) -> gen_tcp:recv(S,0,3000),gen_tcp:close(S).
report({Pid,Ref,L}) ->
    receive {Ref,Head,Body} -> {Head,Body}
    after 4000 -> gen_tcp:close(L),exit(Pid,kill),{<<>>,<<>>} end.
