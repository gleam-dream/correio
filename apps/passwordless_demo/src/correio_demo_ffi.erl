-module(correio_demo_ffi).
-behaviour(gen_server).
-export([start/2, call/2, stop/1, random_token/0, milliseconds/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
random_token() -> base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).
milliseconds() -> erlang:system_time(millisecond).
start(Initial, Handler) ->
  case gen_tcp:listen(0, [binary, {active, false}, {packet, http_bin}, {packet_size, 8192}, {reuseaddr, true}, {ip, {127,0,0,1}}, {backlog, 32}]) of
    {error, _} -> {error, nil};
    {ok, Listen} ->
      {ok, {_, Port}} = inet:sockname(Listen),
      {ok, State} = gen_server:start(?MODULE, {self(), Initial(Port), Handler}, []),
      Listener = spawn(fun() -> accept(Listen, State) end),
      ok = gen_tcp:controlling_process(Listen, Listener),
      spawn(fun() -> watch_lifetime(State, Listener, Listen) end),
      {ok, {{State, Listener, Listen}, Port}}
  end.
call({State, _, _}, Function) ->
  try gen_server:call(State, {admin, Function}, 5000) of Value -> {ok, Value}
  catch _:_ -> {error, nil} end.
stop({State, Listener, Listen}) ->
  ListenerRef = monitor(process, Listener), StateRef = monitor(process, State),
  gen_tcp:close(Listen),
  receive {'DOWN', ListenerRef, process, Listener, _} -> ok
  after 100 -> exit(Listener, kill), receive {'DOWN', ListenerRef, process, Listener, _} -> ok end end,
  catch gen_server:stop(State, normal, 5000),
  receive {'DOWN', StateRef, process, State, _} -> {ok, nil}
  after 5000 -> {error, nil} end.

watch_lifetime(State, Listener, Listen) ->
  StateRef = monitor(process, State), ListenerRef = monitor(process, Listener),
  receive
    {'DOWN', StateRef, process, State, _} -> gen_tcp:close(Listen), exit(Listener, shutdown);
    {'DOWN', ListenerRef, process, Listener, _} -> catch gen_server:stop(State, normal, 5000)
  end.
init({Owner, State, Handler}) -> {ok, {monitor(process, Owner), State, Handler}}.
handle_call({admin, Function}, _From, {Owner, State, Handler}) ->
  {Next, Reply} = Function(State), {reply, Reply, {Owner, Next, Handler}};
handle_call({request, Request}, _From, {Owner, State, Handler}) ->
  try Handler(State, Request) of {Next, Reply} -> {reply, Reply, {Owner, Next, Handler}}
  catch _:_ -> {reply, {response, 500, [], <<"Internal error">>}, {Owner, State, Handler}} end.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Ref, process, _, _}, {Ref, _, _} = State) -> {stop, normal, State};
handle_info(_, State) -> {noreply, State}.
accept(Listen, State) ->
  case gen_tcp:accept(Listen) of
    {ok, Socket} ->
      Response = case read_request(Socket) of
        {ok, Request} -> try gen_server:call(State, {request, Request}, 15000) catch _:_ -> {response, 503, [], <<"Unavailable">>} end;
        {error, _} -> {response, 400, [], <<"Bad request">>}
      end,
      send_response(Socket, Response), gen_tcp:close(Socket), accept(Listen, State);
    {error, closed} -> ok;
    {error, _} -> gen_tcp:close(Listen)
  end.
read_request(Socket) ->
  case gen_tcp:recv(Socket, 0, 5000) of
    {ok, {http_request, Method, {abs_path, Target}, _}} when byte_size(Target) =< 2048 -> headers(Socket, atom_to_binary(Method), Target, [], 0, 0);
    _ -> {error, malformed}
  end.
headers(Socket, Method, Target, Headers, Count, Bytes) when Count < 32, Bytes < 8192 ->
  case gen_tcp:recv(Socket, 0, 5000) of
    {ok, {http_header, _, Name, _, Value}} ->
      Key = string:lowercase(case is_atom(Name) of true -> atom_to_binary(Name); false -> Name end),
      headers(Socket, Method, Target, [{Key, Value} | Headers], Count+1, Bytes+byte_size(Key)+byte_size(Value));
    {ok, http_eoh} -> body(Socket, Method, Target, Headers);
    _ -> {error, malformed}
  end;
headers(_, _, _, _, _, _) -> {error, size}.
body(Socket, Method, Target, Headers) ->
  try
    false = lists:keymember(<<"transfer-encoding">>, 1, Headers),
    Length = case lists:keyfind(<<"content-length">>, 1, Headers) of false -> 0; {_, Value} -> binary_to_integer(Value) end,
    true = Length >= 0 andalso Length =< 4096,
    ok = inet:setopts(Socket, [{packet, raw}]),
    case Length of 0 -> {ok, {request, Method, Target, Headers, <<>>}};
      _ -> case gen_tcp:recv(Socket, Length, 5000) of {ok, Body} -> {ok, {request, Method, Target, Headers, Body}}; _ -> {error, body} end
    end
  catch _:_ -> {error, malformed} end.
send_response(Socket, {response, Status, Headers, Body}) ->
  gen_tcp:send(Socket, ["HTTP/1.1 ", integer_to_list(Status), " Response\r\nConnection: close\r\nContent-Length: ", integer_to_list(byte_size(Body)), "\r\n", [[Name, ": ", Value, "\r\n"] || {Name,Value} <- Headers], "\r\n", Body]).
