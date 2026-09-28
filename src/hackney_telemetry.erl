%%% @doc Updates the metrics that hackney_telemetry reports.
%%%
%%% `hackney_telemetry_middleware' calls this module to update the request
%%% metrics. Each metric has a `hackney_telemetry_worker' which keeps its
%%% current value and generates Telemetry events.
%%%
%%% Metrics are identified by a name, which is a list of atoms, e.g.:
%%%
%%% - [hackney, total_requests]
%%% - [hackney, nb_requests]
%%% @end

-module(hackney_telemetry).

-export([
    increment_counter/1, increment_counter/2,
    update_gauge/2
]).

-include("hackney_telemetry.hrl").

%% @doc Increment counter metric by 1.

-spec increment_counter(hackney_metric()) -> ok.
increment_counter(Metric) ->
    increment_counter(Metric, 1).

%% @doc Increment counter metric by the given value.

-spec increment_counter(hackney_metric(), non_neg_integer()) -> ok.
increment_counter(Metric, Value) ->
    hackney_telemetry_worker:update(Metric, Value, fun sum/2),
    ok.

%% @doc Update gauge metric.
%%
%% Gauges only keep the latest value, so we just need to replace the old state.
%%
%% @end

-spec update_gauge(hackney_metric(), any()) -> ok.
update_gauge(Metric, Value) ->
    hackney_telemetry_worker:update(Metric, Value, fun replace/2).

%% Transform functions

sum(StateValue, EventValue) ->
    StateValue + EventValue.

replace(_StateValue, EventValue) ->
    EventValue.
