%%%-------------------------------------------------------------------
%% @doc emqx_http_lib public API
%% @end
%%%-------------------------------------------------------------------

-module(emqx_http_lib_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    emqx_http_lib_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
