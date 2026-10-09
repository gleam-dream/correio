-module(correio_postgres_test_ffi).
-export([proxy_start/0, proxy_url/1, proxy_arm/1, proxy_confirmed/1, proxy_stop/1]).
-export([database_url/0, stop_pool/1, parallel/2, counter/0, increment/1]).
database_url() -> case os:getenv("DATABASE_URL") of false -> error(use_with_postgres_script); URL -> list_to_binary(URL) end.
stop_pool(Pid) -> unlink(Pid), gen_server:stop(Pid, normal, 5000), nil.
counter() -> atomics:new(1, []).
increment(R) -> atomics:add_get(R, 1, 1).
parallel(Inputs, Function) ->
  Parent = self(), Ref = make_ref(),
  Workers = [spawn_link(fun() -> receive {start, Ref} -> Parent ! {Ref, Function(Input)} end end) || Input <- Inputs],
  [P ! {start, Ref} || P <- Workers],
  [receive {Ref, Reply} -> Reply after 15000 -> error(worker_timeout) end || _ <- Workers].

%% A protocol-aware local fault peer. Forward COMMIT, wait for PostgreSQL's
%% COMMIT/ReadyForQuery acknowledgement, then close without forwarding it.
%% The pool reconnects through the same peer for recovery.
proxy_start() ->
  URI = uri_string:parse(database_url()),
  Host = binary_to_list(maps:get(host, URI)), Port = maps:get(port, URI),
  {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {ip, {127,0,0,1}}]),
  {ok, {_, LocalPort}} = inet:sockname(Listen),
  Flag = atomics:new(1, []),
  Pid = spawn(fun() -> proxy_accept(Listen, Host, Port, Flag) end),
  {Pid, LocalPort, Flag}.
proxy_url({_Pid, Port, _Flag}) -> <<"postgres://app@127.0.0.1:", (integer_to_binary(Port))/binary, "/app">>.
proxy_arm({_Pid, _Port, Flag}) -> atomics:put(Flag, 1, 1), nil.
proxy_confirmed({_Pid, _Port, Flag}) -> atomics:get(Flag, 1) =:= 3.
proxy_stop({Pid, _Port, _Flag}) -> exit(Pid, kill), nil.
proxy_accept(Listen, Host, Port, Flag) ->
  {ok, Client} = gen_tcp:accept(Listen),
  Worker = spawn_link(fun() -> receive {client, Client} ->
    {ok, Server} = gen_tcp:connect(Host, Port, [binary, {active, true}], 5000),
    inet:setopts(Client, [{active, true}]),
    proxy_loop(Client, Server, Flag, startup, <<>>, <<>>, false)
  end end),
  ok = gen_tcp:controlling_process(Client, Worker), Worker ! {client, Client},
  proxy_accept(Listen, Host, Port, Flag).
proxy_loop(Client, Server, Flag, Phase, ClientBuffer, ServerBuffer, Drop) ->
  receive
    {tcp, Client, Bytes} ->
      {NextPhase, Rest, Commit} = client_messages(Phase, <<ClientBuffer/binary, Bytes/binary>>, false),
      Trigger = Commit andalso atomics:compare_exchange(Flag, 1, 1, 2) =:= ok,
      ok = gen_tcp:send(Server, Bytes),
      proxy_loop(Client, Server, Flag, NextPhase, Rest, ServerBuffer, Drop orelse Trigger);
    {tcp, Server, Bytes} when Drop ->
      {Rest, Committed} = committed_messages(<<ServerBuffer/binary, Bytes/binary>>, false),
      case Committed of
        true -> atomics:put(Flag, 1, 3), gen_tcp:close(Client), gen_tcp:close(Server);
        false -> proxy_loop(Client, Server, Flag, Phase, ClientBuffer, Rest, Drop)
      end;
    {tcp, Server, Bytes} ->
      ok = gen_tcp:send(Client, Bytes),
      proxy_loop(Client, Server, Flag, Phase, ClientBuffer, <<>>, Drop);
    {tcp_closed, _} -> gen_tcp:close(Client), gen_tcp:close(Server);
    {tcp_error, _, _} -> gen_tcp:close(Client), gen_tcp:close(Server)
  after 30000 -> gen_tcp:close(Client), gen_tcp:close(Server)
  end.
client_messages(startup, <<Length:32, Payload:(Length-4)/binary, Rest/binary>>, Commit) when Length >= 8 ->
  <<Code:32, _/binary>> = Payload,
  Next = case Code of 196608 -> messages; _ -> startup end,
  client_messages(Next, Rest, Commit);
client_messages(messages, <<Tag, Length:32, Payload:(Length-4)/binary, Rest/binary>>, Commit) when Length >= 4 ->
  IsCommit = case Tag of
    $P -> case binary:split(Payload, <<0>>, [global]) of [_, <<"commit">> | _] -> true; _ -> false end;
    $Q -> Payload =:= <<"commit", 0>>;
    _ -> false
  end,
  client_messages(messages, Rest, Commit orelse IsCommit);
client_messages(Phase, Rest, Commit) -> {Phase, Rest, Commit}.
committed_messages(<<Tag, Length:32, Payload:(Length-4)/binary, Rest/binary>>, Committed) when Length >= 4 ->
  case Tag =:= $C andalso Payload =:= <<"COMMIT", 0>> of
    true -> {Rest, true};
    false -> committed_messages(Rest, Committed)
  end;
committed_messages(Rest, Committed) -> {Rest, Committed}.
