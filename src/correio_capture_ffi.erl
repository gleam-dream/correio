-module(correio_capture_ffi).
-export([start/1, record/2, read/1, entries/1, position/1, since/1,
         since_for/2, now_ms/0, sleep/1, clear/1, stop/1]).
start(Capacity) ->
    Owner = self(),
    spawn(fun() -> Monitor = monitor(process,Owner), loop(Monitor,Capacity,0,0,[]) end).
loop(Owner,Capacity,Size,Position,Entries) ->
    receive
        {'DOWN',Owner,process,_,_} -> ok;
        {From, Ref, {record,Message}} when Size < Capacity ->
            Next = Position + 1,
            From ! {Ref,stored},
            loop(Owner,Capacity,Size+1,Next,[{entry,Next,Message}|Entries]);
        {From, Ref, {record,_}} ->
            From ! {Ref,full}, loop(Owner,Capacity,Size,Position,Entries);
        {From,Ref,read} ->
            From ! {Ref,{ok,[M || {entry,_,M} <- lists:reverse(Entries)]}},
            loop(Owner,Capacity,Size,Position,Entries);
        {From,Ref,entries} ->
            From ! {Ref,{ok,lists:reverse(Entries)}},
            loop(Owner,Capacity,Size,Position,Entries);
        {From,Ref,position} ->
            From ! {Ref,{ok,Position}}, loop(Owner,Capacity,Size,Position,Entries);
        {From,Ref,{since,After}} ->
            From ! {Ref,{ok,[M || {entry,Id,M} <- lists:reverse(Entries), Id > After]}},
            loop(Owner,Capacity,Size,Position,Entries);
        {From,Ref,clear} ->
            From ! {Ref,{ok,nil}}, loop(Owner,Capacity,0,Position,[]);
        {From,Ref,stop} -> From ! {Ref,{ok,nil}}
    end.
record(Handle,Message) ->
    case call(Handle,{record,Message}) of
        {error,unavailable} -> stopped;
        {error,deadline_exceeded} -> uncertain;
        Result -> Result
    end.
read(Handle) -> call(Handle,read).
entries(Handle) -> call(Handle,entries).
position(Handle) -> call(Handle,position).
since(Checkpoint) -> since_for(Checkpoint,1000).
since_for({checkpoint,Handle,Position},Timeout) -> call(Handle,{since,Position},Timeout).
now_ms() -> erlang:monotonic_time(millisecond).
sleep(Milliseconds) -> timer:sleep(Milliseconds), nil.
clear(Handle) -> call(Handle,clear).
stop(Handle) -> call(Handle,stop).
call(Handle,Command) -> call(Handle,Command,1000).
call(Handle,Command,Timeout) ->
    %% Alias deactivation discards late replies rather than filling caller mailboxes.
    Alias = alias([reply]), Monitor = monitor(process,Handle),
    Handle ! {Alias,Alias,Command},
    receive
        {Alias,Result} when Command =:= stop ->
            receive {'DOWN',Monitor,process,Handle,_} -> Result end;
        {Alias,Result} -> demonitor(Monitor,[flush]), Result;
        {'DOWN',Monitor,process,Handle,_} -> unalias(Alias), {error,unavailable}
    after Timeout ->
        unalias(Alias), demonitor(Monitor,[flush]), {error,deadline_exceeded}
    end.
