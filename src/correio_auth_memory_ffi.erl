-module(correio_auth_memory_ffi).
-behaviour(gen_server).
-export([start/1, call/2, stop/1, system_milliseconds/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start(State) ->
    case gen_server:start(?MODULE, {self(), State}, []) of
        {ok, Pid} -> {ok, Pid};
        {error, _} -> {error, nil}
    end.
call(Pid, Function) ->
    try gen_server:call(Pid, {apply, Function}, 5000) of
        Reply -> {ok, Reply}
    catch
        exit:{noproc, _} -> {error, unavailable};
        exit:_ -> {error, unknown}
    end.
stop(Pid) ->
    try gen_server:stop(Pid, normal, 5000) of ok -> {ok, nil}
    catch exit:{noproc, _} -> {ok, nil}; exit:_ -> {error, unknown} end.
system_milliseconds() -> erlang:system_time(millisecond).
init({Owner, State}) -> {ok, {monitor(process, Owner), State}}.
handle_call({apply, Function}, _From, {Owner, State}) ->
    {Next, Reply} = Function(State),
    {reply, Reply, {Owner, Next}}.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Ref, process, _, _}, {Ref, _} = State) -> {stop, normal, State};
handle_info(_, State) -> {noreply, State}.
