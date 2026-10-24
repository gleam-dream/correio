-module(oracle_fixture_ffi).
-export([read/1, write/2, env/1, race/1, stop/1]).
read(Path) -> {ok, Value} = file:read_file(Path), Value.
write(Path, Value) -> ok = file:write_file(Path, Value), nil.
env(Name) -> unicode:characters_to_binary(os:getenv(binary_to_list(Name))).
stop(Pid) -> unlink(Pid), exit(Pid, shutdown), nil.
race(Preparations) ->
    Parent = self(), Ref = make_ref(),
    Workers = [spawn_monitor(fun() ->
        {Backend, Run} = Prepare(),
        Parent ! {Ref, ready, self()},
        receive {Ref, go} -> ok after 30000 -> error(barrier_timeout) end,
        Result = Run(),
        Parent ! {Ref, result, self(), {Backend, Result}}
    end) || Prepare <- Preparations],
    [receive {Ref, ready, Pid} -> ok; {'DOWN', _, process, _, Reason} -> error({worker_failed, Reason})
        after 30000 -> error(checkout_timeout) end || {Pid, _} <- Workers],
    [Pid ! {Ref, go} || {Pid, _} <- Workers],
    [receive {Ref, result, Pid, Value} -> demonitor(Monitor, [flush]), Value;
        {'DOWN', Monitor, process, Pid, Reason} -> error({worker_failed, Reason})
        after 60000 -> error(race_timeout) end || {Pid, Monitor} <- Workers].
