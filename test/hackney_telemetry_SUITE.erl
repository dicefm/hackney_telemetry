-module(hackney_telemetry_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

%% Setup/Teardown functions

all() ->
    [increments_counters, updates_gauges].

init_per_suite(Config) ->
    application:ensure_all_started(telemetry),
    Config.

end_per_suite(Config) ->
    application:stop(telemetry),
    Config.

init_per_testcase(_, Config) ->
    ok = telemetry:attach("test_handler", [hackney], fun send_to_self/4, self()),
    Config.

end_per_testcase(_, Config) ->
    telemetry:detach("test_handler"),
    Config.

%% Tests

increments_counters(_) ->
    Metric = [hackney, dull_counter],
    hackney_telemetry_worker:start_link([{metric, Metric}, {report_interval, 0}]),
    hackney_telemetry:increment_counter(Metric),
    1 = receive_measurement(dull_counter),
    hackney_telemetry:increment_counter(Metric, 5),
    6 = receive_measurement(dull_counter).

updates_gauges(_) ->
    Metric = [hackney, dull_gauge],
    hackney_telemetry_worker:start_link([{metric, Metric}, {report_interval, 0}]),
    hackney_telemetry:update_gauge(Metric, 10),
    10 = receive_measurement(dull_gauge),
    hackney_telemetry:update_gauge(Metric, 3),
    3 = receive_measurement(dull_gauge).

%% Helpers

receive_measurement(Key) ->
    receive
        {telemetry_event, [hackney], #{Key := Value}, #{}} -> Value
    after 10 ->
        ct:fail(message_not_received)
    end.

send_to_self(Metric, Measurement, Metadata, TestPid) ->
    TestPid ! {telemetry_event, Metric, Measurement, Metadata},
    ok.
