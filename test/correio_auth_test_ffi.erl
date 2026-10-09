-module(correio_auth_test_ffi).
-export([clock_new/1, clock_get/1, clock_set/2, increment/1, parallel/2]).
clock_new(N) -> R = atomics:new(1, [{signed, true}]), atomics:put(R, 1, N), R.
clock_get(R) -> atomics:get(R, 1).
clock_set(R, N) -> atomics:put(R, 1, N), nil.
increment(R) -> atomics:add_get(R, 1, 1).
parallel(Count, Function) ->
  Parent = self(), Ref = make_ref(),
  Workers = [spawn_link(fun() -> receive {start, Ref} -> Parent ! {Ref, Function()} end end) || _ <- lists:seq(1, Count)],
  [P ! {start, Ref} || P <- Workers],
  [receive {Ref, Reply} -> Reply after 10000 -> error(worker_timeout) end || _ <- Workers].
