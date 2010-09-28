%%%----------------------------------------------------------------------
%%% File    : state_tests.erl
%%% Author  : Alkis Gotovos <el3ctrologos@hotmail.com>
%%% Description : state.erl unit tests
%%%
%%% Created : 25 Sep 2010 by Alkis Gotovos <el3ctrologos@hotmail.com>
%%%----------------------------------------------------------------------

-module(state_tests).

-include_lib("eunit/include/eunit.hrl").

%% Spec for auto-generated test/0 function (eunit).
-spec test() -> 'ok' | {'error', term()}.


-spec save_load_test() -> term().

save_load_test() ->
    state:start(),
    Init = state:empty(),
    state:save(Init),
    ?assertEqual(Init, state:load()),
    state:stop().

-spec extend_trim_test() -> term().

extend_trim_test() ->
    lid:start(),
    state:start(),
    Init = state:empty(),
    Lid = lid:new(c:pid(0, 2, 3), noparent),
    State = state:extend(Init, Lid),
    {NewLid, NewState} = state:trim(State),
    ?assertEqual(NewLid, Lid),
    ?assertEqual(true, state:is_empty(NewState)),
    state:stop(),
    lid:stop().