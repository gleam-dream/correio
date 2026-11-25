-module(correio_auth_memory_ffi).
-behaviour(gen_server).
-export([start/4, call/2, system_milliseconds/0]).
-export([index_new/0, index_insert/3, index_delete/3, index_first/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Runs in the supervisor, so the store is linked to its supervisor only and
%% registered under Name. Cleanup runs inside the store process every
%% Interval milliseconds.
start(Name, State, Cleanup, Interval) ->
    case gen_server:start_link({local, Name}, ?MODULE, {State, Cleanup, Interval}, []) of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, {abnormal, Reason}}
    end.
%% A name that no process holds is unavailable storage: the command was never
%% delivered. Any other exit leaves the command's effect unknown.
call(Name, Function) ->
    try gen_server:call(Name, {apply, Function}, 5000) of
        Reply -> {ok, Reply}
    catch
        exit:{noproc, _} -> {error, unavailable};
        exit:_ -> {error, unknown}
    end.
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
-record(server, {state, cleanup, interval}).
init({State, Cleanup, Interval}) ->
    erlang:send_after(Interval, self(), cleanup),
    {ok, #server{state = State, cleanup = Cleanup, interval = Interval}}.
handle_call({apply, Function}, _From, #server{state = State} = Server) ->
    {Next, Reply} = Function(State),
    {reply, Reply, Server#server{state = Next}}.
handle_cast(_, Server) -> {noreply, Server}.
%% The next pass is scheduled after this one ends, so passes never queue up.
%% A pass that stopped at its batch limit continues behind the waiting commands.
handle_info(cleanup, #server{state = State, cleanup = Cleanup, interval = Interval} = Server) ->
    {Next, More} = Cleanup(State),
    Delay = case More of true -> 0; false -> Interval end,
    erlang:send_after(Delay, self(), cleanup),
    {noreply, Server#server{state = Next}};
handle_info(_, Server) -> {noreply, Server}.
