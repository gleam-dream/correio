-module(benchmark_ffi).
-export([micros/0, parallel/1, metadata/0]).
micros() -> erlang:monotonic_time(microsecond).
metadata() ->
    {unicode:characters_to_binary(erlang:system_info(otp_release)),
     unicode:characters_to_binary(erlang:system_info(version)),
     erlang:system_info(schedulers_online),
     unicode:characters_to_binary(erlang:system_info(system_architecture))}.
parallel(Jobs) ->
    Parent = self(), Ref = make_ref(),
    Workers = [spawn_monitor(fun() ->
        Parent ! {Ref, ready, self()},
        receive {Ref, go} -> ok after 30000 -> error(barrier_timeout) end,
        Value = Job(),
        Parent ! {Ref, result, self(), Value}
    end) || Job <- Jobs],
    [receive {Ref, ready, Pid} -> ok after 30000 -> error(worker_start_timeout) end || {Pid, _} <- Workers],
    Start = micros(),
    [Pid ! {Ref, go} || {Pid, _} <- Workers],
    Results = [receive {Ref, result, Pid, Value} -> demonitor(Monitor, [flush]), Value;
        {'DOWN', Monitor, process, Pid, Reason} -> error({worker_failed, Reason})
        after 120000 -> error(benchmark_timeout) end || {Pid, Monitor} <- Workers],
    {micros() - Start, lists:append(Results)}.
