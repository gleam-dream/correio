-module(correio_auth_test_ffi).
-export([clock_sample/1, await_sample/1, stop_supervisor/1, await_restart/2]).
-export([clock_new/1, clock_get/1, clock_set/2, increment/1, parallel/2]).
clock_new(N) -> R = atomics:new(1, [{signed, true}]), atomics:put(R, 1, N), {R, self()}.
clock_get({R, _}) -> atomics:get(R, 1).
%% Reports each sample to the process that created the clock.
clock_sample({R, Owner}) -> N = atomics:get(R, 1), Owner ! {clock_sample, N}, N.
await_sample(N) -> receive {clock_sample, N} -> {ok, nil} after 5000 -> {error, nil} end.
clock_set({R, _}, N) -> atomics:put(R, 1, N), nil.
increment({R, _}) -> atomics:add_get(R, 1, 1).
parallel(Count, Function) ->
  Parent = self(), Ref = make_ref(),
  Workers = [spawn_link(fun() -> receive {start, Ref} -> Parent ! {Ref, Function()} end end) || _ <- lists:seq(1, Count)],
  [P ! {start, Ref} || P <- Workers],
  [receive {Ref, Reply} -> Reply after 10000 -> error(worker_timeout) end || _ <- Workers].

%% Stops a supervisor started by this process and waits until it is down.
stop_supervisor(Pid) ->
    unlink(Pid),
    Monitor = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Monitor, process, Pid, _} -> nil after 5000 -> error(supervisor_stop_timeout) end.
%% Waits until a process other than Failed is registered under Name. The
%% supervisor restarts the store after it observes the failure, which this
%% process cannot synchronize with, so this polls for at most two seconds.
await_restart(Name, Failed) -> await_restart(Name, Failed, 2000).
await_restart(_, _, 0) -> {error, nil};
await_restart(Name, Failed, Left) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Failed -> {ok, Pid};
        _ -> receive after 1 -> await_restart(Name, Failed, Left - 1) end
    end.
