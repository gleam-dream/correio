-module(correio_auth_test_ffi).
-export([clock_sample/1, await_sample/1, owner_exit/1, owned_by_finished_process/1]).
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

%% Runs Body in a new process that then waits forever, and reports whether an
%% exit signal from a process it started ended it.
owner_exit(Body) ->
    {Pid, Monitor} = spawn_monitor(fun() -> Body(), receive after infinity -> ok end end),
    receive
        {'DOWN', Monitor, process, Pid, normal} -> {error, nil};
        {'DOWN', Monitor, process, Pid, _} -> {ok, stopped_by_store}
    after 2000 -> exit(Pid, kill), {error, nil} end.
%% Runs Body in a process that exits normally, and returns its value after
%% that process and every process monitoring it have observed the exit.
owned_by_finished_process(Body) ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() -> Parent ! {self(), Body()} end),
    receive {Pid, Value} ->
        receive {'DOWN', Monitor, process, Pid, _} -> ok end,
        {ok, Value}
    after 2000 -> exit(Pid, kill), {error, nil} end.
