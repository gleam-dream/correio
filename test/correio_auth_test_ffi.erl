-module(correio_auth_test_ffi).
-export([clock_sample/1, await_sample/1]).
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
