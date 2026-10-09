-module(correio_demo_test_ffi).
-export([browser_run/3]).
-export([partial_request/1, socket_closed/1, port_closed/1]).
-export([new_counter/0, increment/1]).
-export([database_url/0, stop_pool/1, request/5]).
database_url() -> case os:getenv("DATABASE_URL") of false -> error(use_with_postgres_script); URL -> list_to_binary(URL) end.
stop_pool(Pid) -> unlink(Pid), gen_server:stop(Pid, normal, 5000), nil.
request(Port, Method, Target, Headers, Body) ->
  {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 5000),
  ok = gen_tcp:send(Socket, [Method, " ", Target, " HTTP/1.1\r\nHost: attacker.invalid\r\nConnection: close\r\nContent-Length: ", integer_to_list(byte_size(Body)), "\r\n", [[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers], "\r\n", Body]),
  Bytes = receive_all(Socket, <<>>),
  [HeaderBytes, ResponseBody] = binary:split(Bytes, <<"\r\n\r\n">>),
  [StatusLine | Lines] = binary:split(HeaderBytes, <<"\r\n">>, [global]),
  [_, Status, _] = binary:split(StatusLine, <<" ">>, [global]),
  ResponseHeaders = [begin [Key, Value] = binary:split(Line, <<": ">>), {string:lowercase(Key), Value} end || Line <- Lines],
  {response, binary_to_integer(Status), ResponseHeaders, ResponseBody}.
receive_all(Socket, Acc) ->
  case gen_tcp:recv(Socket, 0, 10000) of
    {ok, Bytes} when byte_size(Acc) + byte_size(Bytes) < 100000 -> receive_all(Socket, <<Acc/binary, Bytes/binary>>);
    {error, closed} -> Acc;
    Other -> error({http_receive_failed, Other})
  end.
new_counter() -> atomics:new(1, []).
increment(Ref) -> atomics:add_get(Ref, 1, 1).
partial_request(Port) ->
  {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 5000),
  ok = gen_tcp:send(Socket, <<"POST /confirm HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\nx">>), Socket.
socket_closed(Socket) -> case gen_tcp:recv(Socket, 0, 6000) of {error, closed} -> true; {ok, _} -> socket_closed(Socket); _ -> false end.
port_closed(Port) -> case gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 100) of {error, econnrefused} -> true; {ok, Socket} -> gen_tcp:close(Socket), false; _ -> false end.
browser_run(Origin, Link, Preview) ->
  Node = case os:getenv("CORREIO_BROWSER_NODE") of false -> os:find_executable("node"); Explicit -> Explicit end,
  false =:= Node andalso error(node_required),
  Port = open_port({spawn_executable, Node}, [binary, exit_status, use_stdio, {line, 8192}, {args, ["browser-e2e.mjs", binary_to_list(Origin)]}]),
  browser_messages(Port, Link, Preview).
browser_messages(Port, Link, Preview) ->
  receive
    {Port, {data, {eol, <<"ISSUED">>}}} -> port_command(Port, [Link(), <<"\n">>]), browser_messages(Port, Link, Preview);
    {Port, {data, {eol, <<"PREVIEW">>}}} ->
      case Preview() of true -> port_command(Port, <<"CONTINUE\n">>), browser_messages(Port, Link, Preview); false -> port_close(Port), {error, nil} end;
    {Port, {data, {eol, Line}}} -> io:format("~s~n", [Line]), browser_messages(Port, Link, Preview);
    {Port, {data, {noeol, _}}} -> port_close(Port), {error, nil};
    {Port, {exit_status, 0}} -> {ok, nil};
    {Port, {exit_status, _}} -> {error, nil}
  after 60000 -> port_close(Port), {error, nil}
  end.
