-module(waiting).

-export([waiting/0]).
-export([scenarios/0]).

scenarios() -> [{?MODULE, inf, dpor, crash}].

waiting() ->
    timer:sleep(25000).
