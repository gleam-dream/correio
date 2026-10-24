-module(correio_mail_test_ffi).
-export([peer/1, report/1, report_closed/1, certificate/0, wire_semantics/1]).

certificate() -> {ok,Pem} = file:read_file("test/mail/certs/ca.pem"), Pem.
peer(Mode) ->
    {ok,L} = gen_tcp:listen(0,[binary,{packet,line},{active,false},{reuseaddr,true},{ip,{127,0,0,1}}]),
    {ok,{_,Port}} = inet:sockname(L),
    Parent=self(),Ref=make_ref(),
    Pid=spawn(fun() ->
        put(commands,[]),put(data,[]),put(recipients,0),put(remote_closed,false),
        try
            {ok,S} = gen_tcp:accept(L,5000),
            gen_tcp:close(L),
            case Mode of
                implicit_tls ->
                    application:ensure_all_started(ssl),
                    {ok,Tls} = ssl:handshake(S,[{certfile,"test/mail/certs/cert.pem"},{keyfile,"test/mail/certs/key.pem"},{verify,verify_none}],2000),
                    smtp({ssl,Tls},Mode);
                hang_banner -> put(remote_closed,gen_tcp:recv(S,0,3000) =:= {error,closed});
                _ -> smtp({gen_tcp,S},Mode)
            end
        catch _:_ -> ok
        after
            gen_tcp:close(L),
            Parent ! {Ref,lists:reverse(get(commands)),iolist_to_binary(lists:reverse(get(data))),get(remote_closed)}
        end
    end),
    {Port,{Pid,Ref,L}}.

smtp(Socket,Mode) -> send(Socket,<<"220 test.local ESMTP\r\n">>), loop(Socket,Mode).
loop(Socket,Mode) ->
    case recv(Socket) of
        {ok,Line} ->
            put(commands,[Line|get(commands)]),
            case Line of
                <<"EHLO",_/binary>> ->
                    case {Socket,Mode} of
                        {{gen_tcp,_},starttls} -> send(Socket,<<"250-test.local\r\n250 STARTTLS\r\n">>);
                        _ -> send(Socket,<<"250 test.local\r\n">>)
                    end,
                    loop(Socket,Mode);
                <<"STARTTLS\r\n">> ->
                    send(Socket,<<"220 upgrade\r\n">>),
                    {gen_tcp,Tcp}=Socket,
                    application:ensure_all_started(ssl),
                    {ok,Tls}=ssl:handshake(Tcp,[{certfile,"test/mail/certs/cert.pem"},{keyfile,"test/mail/certs/key.pem"},{verify,verify_none}],2000),
                    loop({ssl,Tls},Mode);
                <<"HELO",_/binary>> -> send(Socket,<<"250 test.local\r\n">>), loop(Socket,Mode);
                <<"MAIL FROM:",_/binary>> -> send(Socket,<<"250 accepted\r\n">>), loop(Socket,Mode);
                <<"RCPT TO:",_/binary>> ->
                    N=get(recipients)+1,put(recipients,N),
                    case {Mode,N} of {refuse_second,2} -> send(Socket,<<"550 recipient refused\r\n">>); _ -> send(Socket,<<"250 accepted\r\n">>) end,
                    loop(Socket,Mode);
                <<"DATA\r\n">> ->
                    send(Socket,<<"354 proceed\r\n">>), read_data(Socket),
                    case Mode of
                        disconnect_after_data -> close(Socket);
                        hang_data -> put(remote_closed,recv(Socket) =:= {error,closed}), close(Socket);
                        reject_data -> send(Socket,<<"451 not accepted\r\n">>),loop(Socket,Mode);
                        _ -> send(Socket,<<"250 queued-as-local-id\r\n">>),loop(Socket,Mode)
                    end;
                <<"QUIT",_/binary>> -> close(Socket);
                _ -> send(Socket,<<"500 unsupported\r\n">>),loop(Socket,Mode)
            end;
        _ -> close(Socket)
    end.
read_data(Socket) ->
    case recv(Socket) of
        {ok,<<".\r\n">>} -> ok;
        {ok,Line} -> put(data,[Line|get(data)]),read_data(Socket);
        _ -> error(closed)
    end.
send({Module,Socket},Data) -> Module:send(Socket,Data).
recv({Module,Socket}) -> Module:recv(Socket,0,3000).
close({Module,Socket}) -> Module:close(Socket).
report({Pid,Ref,L}) ->
    receive {Ref,Commands,Data,_Closed} -> {Commands,Data}
    after 4000 -> gen_tcp:close(L),exit(Pid,kill),{[],<<>>} end.
report_closed({Pid,Ref,L}) ->
    receive {Ref,_Commands,_Data,Closed} -> Closed
    after 4000 -> gen_tcp:close(L),exit(Pid,kill),false end.

wire_semantics(Raw) ->
    %% Python's independent standard-library parser verifies this fixed public
    %% test fixture. No production content is passed through command arguments.
    Python = os:find_executable("python3"),
    Script = "import base64,email,email.policy,sys; m=email.message_from_bytes(base64.b64decode(sys.argv[1]),policy=email.policy.default); p=list(m.iter_parts()); assert m.get_content_type()=='multipart/mixed'; assert p[0].get_payload(decode=True)==b'hello\\nworld'; assert p[1].get_payload(decode=True)==bytes([0,255,128,13,10]); assert p[1].get_filename()=='binary.dat'",
    Port = open_port({spawn_executable,Python},[exit_status,{args,["-c",Script,binary_to_list(base64:encode(Raw))]}]),
    receive {Port,{exit_status,Status}} -> Status =:= 0 after 3000 -> port_close(Port), false end.
