-module(hackney_telemetry_sup_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

%% Setup/Teardown functions

all() ->
    [starts_request_workers_and_pool_poller].

init_per_suite(Config) ->
    application:ensure_all_started([telemetry, hackney]),
    Config.

end_per_suite(Config) ->
    application:stop(hackney),
    application:stop(telemetry),
    Config.

init_per_testcase(_, Config) ->
    {ok, Pid} = hackney_telemetry_sup:start_link(),
    [{sup_pid, Pid} | Config].

end_per_testcase(_, Config) ->
    SupPid = ?config(sup_pid, Config),
    exit(SupPid, shutdown),
    Config.

%% Tests

starts_request_workers_and_pool_poller(_Config) ->
    Ids = [Id || {Id, _Pid, _Type, _Modules} <- supervisor:which_children(hackney_telemetry_sup)],
    [
        hackney_telemetry_pool_poller,
        {hackney_telemetry_worker, [hackney, finished_requests]},
        {hackney_telemetry_worker, [hackney, nb_requests]},
        {hackney_telemetry_worker, [hackney, total_requests]}
    ] = lists:sort(Ids).
