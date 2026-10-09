-module(correio_testing_test_ffi).
-export([after_delay/2, join/1, suspend/1, resume/1, now_ms/0, caller_predicate/0]).
after_delay(Delay, Function) ->
    spawn_monitor(fun() -> timer:sleep(Delay), Function() end).
join({Pid, Monitor}) ->
    receive {'DOWN', Monitor, process, Pid, Reason} -> Reason =:= normal
    after 2000 -> false end.
suspend({capture, Pid}) -> erlang:suspend_process(Pid), nil.
resume({capture, Pid}) -> erlang:resume_process(Pid), nil.
now_ms() -> erlang:monotonic_time(millisecond).
caller_predicate() ->
    Caller = self(),
    fun(_) -> self() =:= Caller end.
