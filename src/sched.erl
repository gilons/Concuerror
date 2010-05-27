%%%----------------------------------------------------------------------
%%% File    : sched.erl
%%% Author  : Alkis Gotovos <el3ctrologos@hotmail.com>
%%% Description : Scheduler
%%%
%%% Created : 16 May 2010 by Alkis Gotovos <el3ctrologos@hotmail.com>
%%%----------------------------------------------------------------------

%% @doc: The scheduler.

-module(sched).

%% UI related exports.
-export([analyze/4]).

%% Instrumentation related exports.
-export([rep_link/1, rep_receive/1, rep_receive_notify/2,
	 rep_send/2, rep_spawn/1, rep_yield/0]).

-include("gen.hrl").

%%%----------------------------------------------------------------------
%%% Eunit related
%%%----------------------------------------------------------------------

%% -define(NODEBUG, true).
-include_lib("eunit/include/eunit.hrl").

%% Spec for auto-generated test/0 function (eunit).
-spec test() -> 'ok' | {'error', term()}.

%%%----------------------------------------------------------------------
%%% Definitions
%%%----------------------------------------------------------------------

-ifdef(DEBUG).
-define(debug(S_, L_), io:format("(Debug) " ++ S_, L_)).
-else.
-define(debug(S_, L_), ok).
-endif.

%%%----------------------------------------------------------------------
%%% Types
%%%----------------------------------------------------------------------

%% @type: lid() = string().
%% The logical id (LID) for each process reflects the process' logical
%% position in the program's "process creation tree" and doesn't change
%% between different runs of the same program (as opposed to erlang pids).
-type lid() :: string().
%% @type: state() = atom().
%% A state is a list of LIDs showing the (reverse) interleaving of
%% processes up to a point of the program.
-type state() :: [lid()].
%% @type: dest() =  pid() | port() | atom() | {atom(), atom()}.
%% The destination of a `send' operation.
-type dest() :: pid() | port() | atom() | {atom(), node()}.
%% @type: error_descr() = 'deadlock'.
-type error_descr() :: 'deadlock'.
%% @type: analysis_ret() = 'ok' |
%%                         {error, instr} |
%%                         {error, analysis, [{error_descr(), state()}]}.
-type analysis_ret() :: 'ok' |
                        {error, instr} |
                        {error, analysis, [{error_descr(), state()}]}.

%%%----------------------------------------------------------------------
%%% Records
%%%----------------------------------------------------------------------

%% Scheduler state
%%
%% active:  A set containing all processes ready to be scheduled.
%% blocked: A set containing all processes that cannot be scheduled next
%%          (e.g. waiting for a message on a `receive`).
%% state:   The current state of the program.
-record(info, {active  :: set(),
               blocked :: set(),
               state   :: state()}).

%% Internal message format
%%
%% msg:     An atom describing the type of the message.
%% pid:     The sender's pid.
%% misc:    A list of optional arguments, depending on the the message type.
-record(sched, {msg  :: atom(),
                pid  :: pid(),
                misc :: [term()]}).

%%%----------------------------------------------------------------------
%%% User interface
%%%----------------------------------------------------------------------

%% @spec: analyze([file()], atom(), atom(), [term()]) -> analysis_ret()
%% @doc: Instrument one or more files and produce all interleavings of running
%%       `Mod:Fun(Args)'.
-spec analyze([file()], module(), atom(), [term()]) -> analysis_ret().

analyze(Files, Mod, Fun, Args) ->
    case instr:instrument_and_load(Files) of
	ok ->
	    case interleave(Mod, Fun, Args) of
		ok -> ok;
		{error, ErrorStates} -> {error, analysis, ErrorStates}
	    end;
	error ->
	    {error, instr}
    end.

%% Produce all possible process interleavings of (Mod, Fun, Args).
interleave(Mod, Fun, Args) ->
    register(?RP_SCHED, self()),
    %% The mailbox is flushed mainly to discard possible `exit` messages
    %% before enabling the `trap_exit` flag.
    flush_mailbox(),
    process_flag(trap_exit, true),
    %% Start state service.
    state_start(),
    %% Insert empty replay state for the first run.
    state_insert(state_init()),
    {T1, _} = statistics(wall_clock),
    Result = interleave_loop(Mod, Fun, Args, 1, []),
    {T2, _} = statistics(wall_clock),
    report_elapsed_time(T1, T2),
    state_stop(),
    unregister(?RP_SCHED),
    Result.

%% Main loop for producing process interleavings.
interleave_loop(Mod, Fun, Args, RunCounter, Errors) ->
    %% Lookup state to replay.
    case state_pop() of
        no_state ->
	    case Errors of
		[] -> ok;
		_Any -> {error, lists:reverse(Errors)}
	    end;
        ReplayState ->
            log:log("Running interleaving ~p~n", [RunCounter]),
            log:log("----------------------~n"),
            %% Start LID service.
            lid_start(),
            %% Create the first process.
            %% The process is created linked to the scheduler, so that the
            %% latter can receive the former's exit message when it terminates.
            %% In the same way, every process that may be spawned in the course
            %% of the program shall be linked to this process.
            FirstPid = spawn_link(Mod, Fun, Args),
            %% Create the first LID and register it with FirstPid.
            lid_new(FirstPid),
            %% The initial `active` and `blocked` sets are empty.
            Active = set_new(),
            Blocked = set_new(),
            %% Create initial state.
            State = state_init(),
            %% Receive the first message from the first process. That is, wait
            %% until it yields, blocks or terminates.
            NewInfo = dispatcher(#info{active = Active,
                                       blocked = Blocked,
                                       state = State}),
            %% Use driver to replay ReplayState.
            Ret = driver(NewInfo, ReplayState),
	    %% TODO: Proper cleanup of any remaining processes.
            %% Stop LID service (LID tables have to be reset on each run).
            lid_stop(),
            case Ret of
                ok -> interleave_loop(Mod, Fun, Args, RunCounter + 1, Errors);
                {error, ErrorDescr, ErrorState} ->
		    interleave_loop(Mod, Fun, Args, RunCounter + 1,
				    [{ErrorDescr, ErrorState} | Errors]) 
            end
    end.

%%%----------------------------------------------------------------------
%%% Core components
%%%----------------------------------------------------------------------

%% Delegates messages sent by instrumented client code to the appropriate
%% handlers.
dispatcher(Info) ->
    receive
	#sched{msg = block, pid = Pid} ->
	    handler(block, Pid, Info, []);
	#sched{msg = link, pid = Pid, misc = [TargetPid]} ->
	    handler(link, Pid, Info, [TargetPid]);
	#sched{msg = 'receive', pid = Pid, misc = [From, Msg]} ->
	    handler('receive', Pid, Info, [From, Msg]);
	#sched{msg = send, pid = Pid, misc = [Dest, Msg]} ->
	    handler(send, Pid, Info, [Dest, Msg]);
	#sched{msg = spawn, pid = Pid, misc = [ChildPid]} ->
	    handler(spawn, Pid, Info, [ChildPid]);
	#sched{msg = yield, pid = Pid} ->
	    handler(yield, Pid, Info, []);
	{'EXIT', Pid, Reason} ->
	    handler(exit, Pid, Info, [Reason]);
	Other ->
	    log:internal("Dispatcher received: ~p~n", [Other])
    end.

%% Main scheduler component.
%% Checks for different program states (normal, deadlock, termination, etc.)
%% and acts appropriately. The argument should be a blocked scheduler state,
%% i.e. no process running, when the driver is called.
%% In the case of a normal (meaning non-terminal) state, the search component
%% is called to handle state expansion and returns a process for activation.
%% After activating said process the dispatcher is called to delegate the
%% messages received from the running process to the appropriate handler
%% functions.
driver(#info{active = Active, blocked = Blocked, state = State} = Info) ->
    %% Deadlock/Termination check.
    %% If the `active` set is empty and the `blocked` set is non-empty, report
    %% a deadlock, else if both sets are empty, report program termination.
    case set_is_empty(Active) of
	true ->
	    log:log("-----------------------~n"),
	    log:log("Run terminated.~n~n"),
	    case set_is_empty(Blocked) of
		true -> ok;
		false -> {error, deadlock, State}
	    end;
	false ->
	    %% Run search algorithm to find next process to be run.
	    Next = search(Info),
	    %% Remove process Next from the `active` set and run it.
	    NewActive = set_remove(Active, Next),
	    ?debug("Running process ~s.~n", [Next]),
	    run(Next),
	    %% Create new state.
	    NewState = state_get_next(State, Next),
	    %% Call the dispatcher to handle incoming messages from the
	    %% running process.
	    NewInfo = dispatcher(Info#info{active = NewActive,
                                           state = NewState}),
	    driver(NewInfo)
    end.

%% Same as above, but instead of searching, the process to be activated is
%% provided at each step by the head of the State argument. When the State list
%% is empty, the driver falls back to the standard search behaviour stated
%% above.
driver(Info, []) -> driver(Info);
driver(#info{active = Active, blocked = Blocked, state = State} = Info,
       [Next|Rest]) ->
    %% Deadlock/Termination check.
    %% If the `active` set is empty and the `blocked` set is non-empty, report
    %% a deadlock, else if both sets are empty, report program termination.
    case set_is_empty(Active) of
	true ->
	    log:log("-----------------------~n"),
	    log:log("Run terminated.~n~n"),
	    case set_is_empty(Blocked) of
		true -> ok;
		false -> {error, deadlock, State}
	    end;
	false ->
	    %% Remove process Next from the `active` set and run it.
	    NewActive = set_remove(Active, Next),
	    ?debug("Running process ~s.~n", [Next]),
	    run(Next),
	    %% Create new state.
	    NewState = state_get_next(State, Next),
	    %% Call the dispatcher to handle incoming messages from the
	    %% running process.
	    NewInfo = dispatcher(Info#info{active = NewActive,
                                           state = NewState}),
	    driver(NewInfo, Rest)
    end.

%% Implements the search logic (currently depth-first when looked at combined
%% with the replay logic).
%% Given a blocked state (no process running when called), creates all
%% possible next states, chooses one of them for running and inserts the rest
%% of them into the `states` table.
%% Returns the process to be run next.
search(#info{active = Active, state = State} = Info) ->
    %% Remove a process from the `actives` set and run it.
    {Next, NewActive} = set_pop(Active),
    %% Store all other possible successor states in `states` table for later
    %% exploration.
    state_insert_succ(Info#info{active = NewActive, state = State}),
    Next.

%% Block message handler.
%% Receiving a `block` message means that the process cannot be scheduled
%% next and must be moved to the blocked set.
handler(block, Pid, #info{blocked = Blocked} = Info, _Opt) ->
    Lid = lid(Pid),
    NewBlocked = set_add(Blocked, Lid),
    log:log("Process ~s blocks.~n", [Lid]),
    Info#info{blocked = NewBlocked};
%% Exit message handler.
%% Discard the exited process (don't add to any set).
%% If the exited process is irrelevant (i.e. has no LID assigned), recall the
%% dispatcher.
handler(exit, Pid, Info, [Reason]) ->
    Lid = lid(Pid),
    case Lid of
	not_found ->
	    ?debug("Process ~s (pid = ~p) exits (~p).~n", [Lid, Pid, Reason]),
	    dispatcher(Info);
	_Any ->
	    log:log("Process ~s exits (~p).~n", [Lid, Reason]),
	    Info
    end;
%% Link message handler.
handler(link, Pid, Info, [TargetPid]) ->
    Lid = lid(Pid),
    TargetLid = lid(TargetPid),
    log:log("Process ~s links to process ~s.~n", [Lid, TargetLid]),
    dispatcher(Info);
%% Receive message handler.
handler('receive', Pid, Info, [From, Msg]) ->
    Lid = lid(Pid),
    SenderLid = lid(From),
    log:log("Process ~s receives message `~p` from process ~s.~n",
	    [Lid, Msg, SenderLid]),
    dispatcher(Info);
%% Send message handler.
%% When a message is sent to a process, the receiving process has to be awaken
%% if it is blocked on a receive.
%% XXX: No check for reason of blocking for now. If the process is blocked on
%%      something else, it will be awaken!
handler(send, Pid, Info, [DstPid, Msg]) ->
    Lid = lid(Pid),
    DstLid = lid(DstPid),
    log:log("Process ~s sends message `~p` to process ~s.~n",
	    [Lid, Msg, DstLid]),
    NewInfo = wakeup(DstLid, Info),
    dispatcher(NewInfo);
%% Spawn message handler.
%% First, link the newly spawned process to the scheduler process.
%% The new process yields as soon as it gets spawned and the parent process
%% yields as soon as it spawns. Therefore wait for two `yield` messages using
%% two calls to the dispatcher.
handler(spawn, ParentPid, Info, [ChildPid]) ->
    link(ChildPid),
    ParentLid = lid(ParentPid),
    ChildLid = lid_new(ParentLid, ChildPid),
    log:log("Process ~s spawns process ~s.~n", [ParentLid, ChildLid]),
    NewInfo = dispatcher(Info),
    dispatcher(NewInfo);
%% Yield message handler.
%% Receiving a `yield` message means that the process is preempted, but
%% remains in the active set.
handler(yield, Pid, #info{active = Active} = Info, _Opt) ->
    case lid(Pid) of
        %% This case clause avoids a possible race between `yield` message
        %% of child and `spawn` message of parent.
        not_found ->
            ?RP_SCHED ! #sched{msg = yield, pid = Pid},
            dispatcher(Info);
        Lid ->
            ?debug("Process ~s yields.~n", [Lid]),
            NewActive = set_add(Active, Lid),
            Info#info{active = NewActive}
    end.

%%%----------------------------------------------------------------------
%%% Helper functions
%%%----------------------------------------------------------------------

%% Flush a process' mailbox.
flush_mailbox() ->
    receive
	_Any -> flush_mailbox()
    after 0 -> ok
    end.

%% Calculate and print elapsed time between T1 and T2.
report_elapsed_time(T1, T2) ->
    ElapsedTime = T2 - T1,
    Mins = ElapsedTime div 60000,
    Secs = (ElapsedTime rem 60000) / 1000,
    log:log("Done in ~wm~.2fs\n", [Mins, Secs]).

%% Signal process Lid to continue its execution.
run(Lid) ->
    Pid = lid_to_pid(Lid),
    Pid ! #sched{msg = continue}.

%% Wakeup a process.
%% If process is in `blocked` set, move to `active` set.
wakeup(Lid, #info{active = Active, blocked = Blocked} = Info) ->
    case set_member(Blocked, Lid) of
	true ->
            ?debug("Process ~p wakes up.~n", [Lid]),
	    NewBlocked = set_remove(Blocked, Lid),
	    NewActive = set_add(Active, Lid),
	    Info#info{active = NewActive, blocked = NewBlocked};
	false ->
	    Info
    end.

%%%----------------------------------------------------------------------
%%% Instrumentation interface
%%%----------------------------------------------------------------------

%% Not actually a replacement function, but used by functions where the process
%% is required to block, i.e. moved to the `blocked` set and stop being
%% scheduled, until awaken.
block() ->
    ?RP_SCHED ! #sched{msg = block, pid = self()},
    receive
	#sched{msg = continue} -> true
    end.

%% @spec: rep_link(pid() | port()) -> 'true'
%% @doc: Replacement for `link/1'.
%%
%% Just yield after linking.
-spec rep_link(pid() | port()) -> 'true'.

rep_link(Pid) ->
    Result = link(Pid),
    ?RP_SCHED ! #sched{msg = link, pid = self(), misc = [Pid]},
    rep_yield(),
    Result.

%% @spec rep_yield() -> 'true'
%% @doc: Replacement for `yield/0'.
%%
%% The calling process is preempted, but remains in the active set and awaits
%% a message to continue.
%%
%% Note: Besides replacing `yield/0', this function is heavily used by other
%%       functions of the instrumentation interface.

-spec rep_yield() -> 'true'.

rep_yield() ->
    ?RP_SCHED ! #sched{msg = yield, pid = self()},
    receive
	#sched{msg = continue} -> true
    end.

%% @spec rep_receive(function((function()) -> term())) -> term()
%% @doc: Replacement for a `receive' statement.
%%
%% The first time the process is scheduled it searches its mailbox. If no
%% matching message is found, it blocks (i.e. is moved to the blocked set).
%% When a new message arrives the process is woken up.
%% The check mailbox - block - wakeup loop is repeated until a matching message
%% arrives.
-spec rep_receive(fun((fun()) -> term())) -> term().

rep_receive(Fun) ->
    rep_receive_aux(Fun).

rep_receive_aux(Fun) ->
    Fun(fun() -> block(), rep_receive_aux(Fun) end).

%% @spec rep_receive_notify(pid(), term()) -> 'ok'
%% @doc: Auxiliary function used in the `receive' statetement instrumentation.
%%
%% Called first thing after a message has been received, to inform the scheduler
%% about the message received and the sender.
-spec rep_receive_notify(pid(), term()) -> 'ok'.

rep_receive_notify(From, Msg) ->
    ?RP_SCHED ! #sched{msg = 'receive', pid = self(), misc = [From, Msg]},
    rep_yield(),
    ok.

%% @spec rep_send(dest(), term()) -> term()
%% @doc: Replacement for `send/2' (and the equivalent `!' operator).
%%
%% Just yield after sending.
-spec rep_send(dest(), term()) -> term().

rep_send(Dest, Msg) ->
    {_Self, RealMsg} = Dest ! Msg,
    ?RP_SCHED ! #sched{msg = send, pid = self(), misc = [Dest, RealMsg]},
    rep_yield(),
    RealMsg.

%% @spec rep_spawn(function()) -> pid()
%% @doc: Replacement for `spawn/1'.
%%
%% The argument provided is the argument of the original spawn call.
%% When spawned, the new process has to yield.
-spec rep_spawn(fun()) -> pid().

rep_spawn(Fun) ->
    Pid = spawn(fun() -> rep_yield(), Fun() end),
    ?RP_SCHED ! #sched{msg = spawn, pid = self(), misc = [Pid]},
    rep_yield(),
    Pid.

%%%----------------------------------------------------------------------
%%% LID interface
%%%----------------------------------------------------------------------

%% Return the LID of process Pid or 'not_found' if mapping not in table.
lid(Pid) ->
    case ets:lookup(?NT_PID, Pid) of
	[{_Pid, Lid}] -> Lid;
	[] -> not_found
    end.

%% "Register" a new process spawned by the process with LID `ParentLID`.
%% Pid is the new process' erlang pid.
%% If called without a `ParentLID` argument, it "registers" the first process.
%% Returns the LID of the newly "registered" process.
lid_new(Pid) ->
    %% The first process has LID = "P1" and has no children spawned at init.
    Lid = "P1",
    ets:insert(?NT_LID, {Lid, Pid, 0}),
    ets:insert(?NT_PID, {Pid, Lid}),
    Lid.

lid_new(ParentLID, Pid) ->
    [{_ParentLID, _ParentPid, Children}] = ets:lookup(?NT_LID, ParentLID),
    %% Create new process' Lid
    Lid = lists:concat([ParentLID, ".", Children + 1]),
    %% Update parent info (increment children counter).
    ets:update_element(?NT_LID, ParentLID, {3, Children + 1}),
    %% Insert child info.
    ets:insert(?NT_LID, {Lid, Pid, 0}),
    ets:insert(?NT_PID, {Pid, Lid}),
    Lid.

%% Initialize LID tables.
%% Must be called before any other call to lid_* functions.
lid_start() ->
    %% Table for storing process info.
    %% Its elements are of the form {Lid, Pid, Children}, where Children
    %% is the number of processes spawned by it so far.
    ets:new(?NT_LID, [named_table]),
    %% Table for reverse lookup (Lid -> Pid) purposes.
    %% Its elements are of the form {Pid, Lid}.
    ets:new(?NT_PID, [named_table]).

%% Clean up LID tables.
lid_stop() ->
    ets:delete(?NT_LID),
    ets:delete(?NT_PID).

%% Return the erlang pid of the process Lid.
lid_to_pid(Lid) ->
    ets:lookup_element(?NT_LID, Lid, 2).

%%%----------------------------------------------------------------------
%%% Set interface
%%%----------------------------------------------------------------------

%% Add Element to Set and return new set.
set_add(Set, Element) ->
    sets:add_element(Element, Set).

%% Return true if Set is empty, false otherwise.
set_is_empty(Set) ->
    sets:to_list(Set) =:= [].

%% Return a list of the elements in Set.
set_list(Set) ->
    sets:to_list(Set).

%% Checks if Element is in Set.
set_member(Set, Element) ->
    sets:is_element(Element, Set).

%% Return a new empty set.
set_new() ->
    sets:new().

%% Remove a "random" element from Set and return that element and the
%% new set.
%% Crashes if given an empty set.
set_pop(Set) ->
    [Head|Tail] = sets:to_list(Set),
    {Head, sets:from_list(Tail)}.

%% Remove Element from Set.
set_remove(Set, Element) ->
    sets:del_element(Element, Set).

%%%----------------------------------------------------------------------
%%% State interface
%%%----------------------------------------------------------------------

%% Given the current state and a process to be run next, return the new state.
state_get_next(State, Next) ->
    [Next|State].

%% Return initial (empty) state.
state_init() ->
    [].

%% Add a state to the `state` table.
state_insert(State) ->
    ets:insert(?NT_STATE, {State}).

%% Create all possible next states and add them to the `state` table.
state_insert_succ(#info{active = Active, state = State}) ->
    state_insert_succ_aux(State, set_list(Active)).

state_insert_succ_aux(_State, []) -> ok;
state_insert_succ_aux(State, [Proc|Procs]) ->
    ets:insert(?NT_STATE, {[Proc|State]}),
    state_insert_succ_aux(State, Procs).

%% Remove and return a state.
%% If no states available, return 'no_state'.
state_pop() ->
    case ets:first(?NT_STATE) of
	'$end_of_table' -> no_state;
	State ->
	    ets:delete(?NT_STATE, State),
	    lists:reverse(State)
    end.

%% Initialize state table.
%% Must be called before any other call to state_* functions.
state_start() ->
    %% Table for storing unvisited states (as keys, the values are irrelevant).
    ets:new(?NT_STATE, [named_table]).

%% Clean up state table.
state_stop() ->
    ets:delete(?NT_STATE).

%%%----------------------------------------------------------------------
%%% Unit tests
%%%----------------------------------------------------------------------

-spec set_test_() -> term().

set_test_() ->
     [{"Empty",
       ?_assertEqual(true, set_is_empty(set_new()))},
      {"Add/remove one",
       ?_test(begin
		  {Result, NewSet} = set_pop(set_add(set_new(), 42)),
		  ?assertEqual(42, Result),
		  ?assertEqual(true, set_is_empty(NewSet))
	      end)},
      {"Add/remove multiple",
      ?_test(begin
		 Set = set_add(set_add(set_add(set_new(), "42"), "P4.2"),
                               "P42"),
		 List1 = lists:sort(set_list(Set)),
		 {Val1, Set1} = set_pop(Set),
		 {Val2, Set2} = set_pop(Set1),
		 {Val3, Set3} = set_pop(Set2),
		 List2 = lists:sort([Val1, Val2, Val3]),
		 ?assertEqual(List1, List2),
		 ?assertEqual(true, set_is_empty(Set3))
	     end)}].

-spec lid_test_() -> term().

lid_test_() ->
     [{"Lid",
       ?_test(begin
		  lid_start(),
		  Pid1 = c:pid(0, 2, 3),
		  Lid1 = lid_new(Pid1),
		  Pid2 = c:pid(0, 2, 4),
		  Lid2 = lid_new(Lid1, Pid2),
		  Pid3 = c:pid(0, 2, 5),
		  Lid3 = lid_new(Lid1, Pid3),
		  P1 = lid_to_pid(Lid1),
		  L1 = lid(Pid1),
		  P2 = lid_to_pid(Lid2),
		  L2 = lid(Pid2),
		  P3 = lid_to_pid(Lid3),
		  L3 = lid(Pid3),
		  L4 = lid(c:pid(0, 2, 6)),
		  lid_stop(),
		  ?assertEqual(P1, Pid1),
		  ?assertEqual(P2, Pid2),
		  ?assertEqual(P3, Pid3),
		  ?assertEqual(L1, Lid1),
		  ?assertEqual(L2, Lid2),
		  ?assertEqual(L3, Lid3),
		  ?assertEqual(L4, 'not_found')
	      end)}].

-spec interleave_test_() -> term().

interleave_test_() ->
    [{"test1",
      ?_assertEqual(ok,
		    analyze(["./test/test.erl"], test, test1, []))},
     {"test2",
      ?_assertEqual(ok,
		    analyze(["./test/test.erl"], test, test2, []))},
     {"test3",
      ?_assertEqual(ok,
		    analyze(["./test/test.erl"], test, test3, []))},
     {"test4",
      ?_assertMatch({error, analysis, _}, 
		    analyze(["./test/test.erl"], test, test4, []))},
     {"test5",
      ?_assertMatch({error, analysis, _},
		    analyze(["./test/test.erl"], test, test5, []))},
     {"test6",
      ?_assertEqual(ok,
		    analyze(["./test/test.erl"], test, test6, []))},
     {"test7",
      ?_assertEqual(ok,
		    analyze(["./test/test.erl"], test, test7, []))},
     {"test9",
      ?_assertEqual(ok,
		    analyze(["./test/test.erl", "./test/test_aux.erl"],
			    test, test9, []))}].
