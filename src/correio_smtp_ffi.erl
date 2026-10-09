-module(correio_smtp_ffi).
-export([submit/9, valid_host/1, valid_roots/1]).

valid_host(Host) -> byte_size(Host) > 0 andalso byte_size(Host) =< 253 andalso
    case inet:parse_address(binary_to_list(Host)) of
        {ok,_} -> true;
        _ -> lists:all(fun(Label) -> byte_size(Label) =< 63 andalso
            re:run(Label, <<"\\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\z">>, [{capture,none}]) =:= match
        end,binary:split(Host,<<".">>,[global]))
    end.
valid_roots(Pem) ->
    try byte_size(Pem) =< 1048576 andalso roots(Pem) =/= [] catch _:_ -> false end.
roots(Pem) ->
    [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem),
            begin public_key:pkix_decode_cert(Der, otp), true end].

submit(Host, Port, Security, Credentials, Timeout, Trust, From, To, Raw) ->
    Parent = self(), Ref = make_ref(),
    %% A peer cannot retain an unlimited multiline reply in the SMTP worker.
    %% The allowance includes the admitted raw binary and dot-stuffed copy.
    HeapWords = (67108864 + 3 * byte_size(Raw)) div erlang:system_info(wordsize),
    {Worker, Monitor} = spawn_opt(fun() ->
        %% The worker's own timer bounds its lifetime if its caller exits.
        {ok, Timer} = timer:kill_after(Timeout),
        Result = exchange(Parent, Ref, Host, Port, Security, Credentials, Timeout, Trust, From, To, Raw),
        Parent ! {Ref, result, Result},
        timer:cancel(Timer)
    end,[monitor,{max_heap_size,#{size => HeapWords,kill => true,error_logger => false,include_shared_binaries => true}}]),
    await(Worker, Monitor, Ref, false, erlang:monotonic_time(millisecond) + Timeout).

await(Worker, Monitor, Ref, Possible, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Ref, possible} -> await(Worker,Monitor,Ref,true,Deadline);
        {Ref, result, Result} ->
            erlang:demonitor(Monitor,[flush]), Result;
        {'DOWN', Monitor, process, Worker, _} -> interrupted(Possible)
    after Remaining ->
        exit(Worker,kill),
        %% DOWN follows this worker's phase notifications. Draining through
        %% DOWN prevents a timeout race from turning possible DATA into no-send.
        stopped(Worker,Monitor,Ref,Possible)
    end.
stopped(Worker, Monitor, Ref, Possible) ->
    receive
        {Ref,possible} -> stopped(Worker,Monitor,Ref,true);
        {Ref,result,Result} ->
            receive {'DOWN',Monitor,process,Worker,_} -> Result end;
        {'DOWN',Monitor,process,Worker,_} -> interrupted(Possible)
    end.
interrupted(true) -> uncertain;
interrupted(false) -> {before_send,deadline_exceeded}.

exchange(Parent, Ref, Host, Port, Security, Credentials, Timeout, Trust, From, To, Raw) ->
    try
        application:ensure_all_started(ssl),
        Options = options(Host,Port,Security,Credentials,Timeout,Trust),
        case gen_smtp_client:open(Options) of
            {ok,Socket} -> deliver(Parent,Ref,Socket,From,To,Raw);
            Error -> {before_send,open_failure(Error)}
        end
    catch _:_ -> {before_send,adapter_failure} end.

deliver(Parent, Ref, Socket, From, To, Raw) ->
    put(correio_possible,false),
    Body = fun() -> put(correio_possible,true), Parent ! {Ref,possible}, Raw end,
    try
        case gen_smtp_client:deliver(Socket,{From,To,Body}) of
            {ok,_Receipt} -> accepted;
            {error,Failure} -> delivery_failure(Failure,get(correio_possible))
        end
    catch _:_ -> case get(correio_possible) of true -> uncertain; false -> {before_send,connection_unavailable} end
    after
        %% Closing is cleanup and cannot invalidate an acceptance receipt.
        %% gen_smtp close sends QUIT without awaiting its acknowledgement.
        catch gen_smtp_client:close(Socket)
    end.

delivery_failure({_, <<"4",_/binary>>}, _) -> {refused,temporary};
delivery_failure({_, <<"5",_/binary>>}, _) -> {refused,permanent};
delivery_failure(_, true) -> uncertain;
delivery_failure(_, false) -> {before_send,connection_unavailable}.

open_failure({error,_,{_,_,Reason}}) -> open_failure(Reason);
open_failure({error,_,{_,Reason}}) -> open_failure(Reason);
open_failure({error,_,Reason}) -> open_failure(Reason);
open_failure({error,Reason}) -> open_failure(Reason);
open_failure({missing_requirement,tls}) -> transport_security;
open_failure({_,tls_failed}) -> transport_security;
open_failure(tls_failed) -> transport_security;
open_failure(tls) -> transport_security;
open_failure({tls_alert,_}) -> transport_security;
open_failure({bad_cert,_}) -> transport_security;
open_failure({missing_requirement,auth}) -> authentication_failed;
open_failure({_,auth_failed}) -> authentication_failed;
open_failure(auth_failed) -> authentication_failed;
open_failure(auth) -> authentication_failed;
open_failure(_) -> connection_unavailable.

options(Host,Port,Security,Credentials,Timeout,Trust) ->
    Base = [{relay,binary_to_list(Host)}, {port,Port}, {hostname,"localhost"},
            {no_mx_lookups,true}, {retries,0}, {timeout,Timeout}, {protocol,smtp}],
    TLS = case Security of
        local_test_plaintext -> [{tls,never},{ssl,false},{sockopts,[{packet_size,8192}]}];
        _ ->
            CAs = case Trust of none -> public_key:cacerts_get(); {some,Pem} -> roots(Pem) end,
            TlsOptions = [{verify,verify_peer}, {cacerts,CAs}, {depth,10},
                          {versions,['tlsv1.2','tlsv1.3']},{packet_size,8192},
                          {server_name_indication,binary_to_list(Host)},
                          {customize_hostname_check,[{match_fun,public_key:pkix_verify_hostname_match_fun(https)}]}],
            case Security of
                start_tls_required -> [{tls,always},{ssl,false},{tls_options,TlsOptions},{sockopts,[{packet_size,8192}]}];
                implicit_tls -> [{tls,never},{ssl,true},{tls_options,TlsOptions},{sockopts,TlsOptions}]
            end
    end,
    Auth = case Credentials of none -> [{auth,never}]; {some,{User,Pass}} -> [{auth,always},{username,binary_to_list(User)},{password,binary_to_list(Pass)}] end,
    Base ++ TLS ++ Auth.
