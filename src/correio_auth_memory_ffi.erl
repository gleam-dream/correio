-module(correio_auth_memory_ffi).
-behaviour(gen_server).
-export([start/3, call/2, stop/1, system_milliseconds/0]).
-export([index_new/0, index_insert/3, index_delete/3, index_first/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Cleanup runs inside the store process every Interval milliseconds.
%% The store is linked to its owner, so a store that fails stops its owner and
%% the owner's supervisor rebuilds both. It also monitors the owner, because a
%% link does not report an owner that exits normally.
start(State, Cleanup, Interval) ->
    case gen_server:start_link(?MODULE, {self(), State, Cleanup, Interval}, []) of
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
%% An ordered set of {Time, Id} entries.
index_new() -> gb_sets:new().
index_insert(Index, At, Id) -> gb_sets:add_element({At, Id}, Index).
index_delete(Index, At, Id) -> gb_sets:del_element({At, Id}, Index).
index_first(Index) ->
    case gb_sets:is_empty(Index) of
        true -> {error, nil};
        false -> {ok, gb_sets:smallest(Index)}
    end.
-record(server, {owner, state, cleanup, interval}).
init({Owner, State, Cleanup, Interval}) ->
    erlang:send_after(Interval, self(), cleanup),
    {ok, #server{owner = monitor(process, Owner), state = State,
                 cleanup = Cleanup, interval = Interval}}.
handle_call({apply, Function}, _From, #server{state = State} = Server) ->
    {Next, Reply} = Function(State),
    {reply, Reply, Server#server{state = Next}}.
handle_cast(_, Server) -> {noreply, Server}.
handle_info({'DOWN', Ref, process, _, _}, #server{owner = Ref} = Server) ->
    {stop, normal, Server};
%% The next pass is scheduled after this one ends, so passes never queue up.
%% A pass that stopped at its batch limit continues behind the waiting commands.
handle_info(cleanup, #server{state = State, cleanup = Cleanup, interval = Interval} = Server) ->
    {Next, More} = Cleanup(State),
    Delay = case More of true -> 0; false -> Interval end,
    erlang:send_after(Delay, self(), cleanup),
    {noreply, Server#server{state = Next}};
handle_info(_, Server) -> {noreply, Server}.
