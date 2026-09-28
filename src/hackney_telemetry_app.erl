%%% @doc hackney_telemetry application.
%%%
%%% Installs the middleware on start and removes it on stop.
%%% @end

-module(hackney_telemetry_app).

-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).

start(_StartType, _StartArgs) ->
    ok = hackney_telemetry:install(),
    hackney_telemetry_sup:start_link().

prep_stop(State) ->
    ok = hackney_telemetry:uninstall(),
    State.

stop(_State) ->
    ok.
