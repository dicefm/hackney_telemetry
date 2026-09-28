-module(hackney_telemetry_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("hackney/include/hackney_lib.hrl").

-define(EVENTS, [
    [hackney],
    [hackney, request, start],
    [hackney, request, stop],
    [hackney, request, exception],
    [hackney, checkout_timeout],
    [hackney_pool],
    [hackney_pool, stats_timeout]
]).

all() ->
    [
        installs_middleware_on_start,
        install_keeps_other_middleware,
        install_is_idempotent,
        uninstall_keeps_other_middleware,
        stopping_the_application_removes_middleware,
        counts_requests_made_through_hackney,
        counts_request_as_in_flight_until_it_finishes,
        counts_request_that_raises_as_finished,
        emits_request_span,
        emits_request_span_for_error,
        emits_request_span_for_head_and_async,
        emits_exception_for_request_that_raises,
        emits_checkout_timeout,
        passes_through_before_install,
        reports_pool_stats,
        skips_pool_that_stopped,
        reports_pool_stats_timeout,
        reporter_reports_periodically,
        reporter_with_zero_interval_does_not_report
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney_telemetry),
    Config.

end_per_suite(Config) ->
    application:stop(hackney_telemetry),
    Config.

init_per_testcase(_TestCase, Config) ->
    ok = telemetry:attach_many(?MODULE, ?EVENTS, fun ?MODULE:send_to_self/4, self()),
    Config.

end_per_testcase(_TestCase, Config) ->
    telemetry:detach(?MODULE),
    application:set_env(hackney, middleware, [fun hackney_telemetry:call/2]),
    Config.

%% Install

installs_middleware_on_start(_Config) ->
    {ok, [Middleware]} = application:get_env(hackney, middleware),
    Middleware = fun hackney_telemetry:call/2.

install_keeps_other_middleware(_Config) ->
    Other = fun ?MODULE:other_middleware/2,
    application:set_env(hackney, middleware, [Other]),
    ok = hackney_telemetry:install(),
    {ok, [Middleware, Other]} = application:get_env(hackney, middleware),
    Middleware = fun hackney_telemetry:call/2.

install_is_idempotent(_Config) ->
    Before = request_counts(),
    ok = hackney_telemetry:install(),
    {ok, [_]} = application:get_env(hackney, middleware),
    Before = request_counts().

uninstall_keeps_other_middleware(_Config) ->
    Other = fun ?MODULE:other_middleware/2,
    application:set_env(hackney, middleware, [fun hackney_telemetry:call/2, Other]),
    ok = hackney_telemetry:uninstall(),
    {ok, [Other]} = application:get_env(hackney, middleware),
    application:set_env(hackney, middleware, [fun hackney_telemetry:call/2]),
    ok = hackney_telemetry:uninstall(),
    undefined = application:get_env(hackney, middleware).

stopping_the_application_removes_middleware(_Config) ->
    ok = application:stop(hackney_telemetry),
    undefined = application:get_env(hackney, middleware),
    ok = application:start(hackney_telemetry),
    {ok, [_]} = application:get_env(hackney, middleware).

%% Counts

counts_requests_made_through_hackney(_Config) ->
    #{total_requests := Total, finished_requests := Finished} = request_counts(),
    {error, _Reason} = hackney:request(get, <<"http://127.0.0.1:1">>, [], <<>>, []),
    #{total_requests := Total2, finished_requests := Finished2} = request_counts(),
    Total2 = Total + 1,
    Finished2 = Finished + 1.

counts_request_as_in_flight_until_it_finishes(_Config) ->
    #{nb_requests := InFlight, total_requests := Total, finished_requests := Finished} =
        request_counts(),
    {ok, 200, [], <<>>} = hackney_telemetry:call(request([]), fun(_Request) ->
        #{nb_requests := InFlight2} = request_counts(),
        InFlight2 = InFlight + 1,
        {ok, 200, [], <<>>}
    end),
    #{nb_requests := InFlight, total_requests := Total2, finished_requests := Finished2} =
        request_counts(),
    Total2 = Total + 1,
    Finished2 = Finished + 1.

counts_request_that_raises_as_finished(_Config) ->
    #{nb_requests := InFlight, finished_requests := Finished} = request_counts(),
    {'EXIT', {boom, _}} = (catch hackney_telemetry:call(request([]), fun(_) -> error(boom) end)),
    #{nb_requests := InFlight, finished_requests := Finished2} = request_counts(),
    Finished2 = Finished + 1.

%% Span

emits_request_span(_Config) ->
    hackney_telemetry:call(request([{pool, stripe}]), fun(_) -> {ok, 201, [], <<"body">>} end),
    Metadata = #{method => post, host => <<"api.example.com">>, pool => stripe},
    receive
        {[hackney, request, start], #{system_time := _}, StartMetadata} ->
            Metadata = maps:with([method, host, pool], StartMetadata)
    after 100 -> ct:fail(start_not_received)
    end,
    receive
        {[hackney, request, stop], #{duration := _}, StopMetadata} ->
            #{status := 201} = StopMetadata,
            Metadata = maps:with([method, host, pool], StopMetadata)
    after 100 -> ct:fail(stop_not_received)
    end.

emits_request_span_for_error(_Config) ->
    hackney_telemetry:call(request([]), fun(_) -> {error, timeout} end),
    receive
        {[hackney, request, stop], _Measurements, Metadata} ->
            #{status := undefined, error := timeout, pool := default} = Metadata
    after 100 -> ct:fail(stop_not_received)
    end,
    receive
        {[hackney, checkout_timeout], _, _} -> ct:fail(unexpected_checkout_timeout)
    after 0 -> ok
    end.

emits_request_span_for_head_and_async(_Config) ->
    hackney_telemetry:call(request([]), fun(_) -> {ok, 204, []} end),
    receive
        {[hackney, request, stop], _, #{status := 204}} -> ok
    after 100 -> ct:fail(head_stop_not_received)
    end,
    hackney_telemetry:call(request([]), fun(_) -> {ok, make_ref()} end),
    receive
        {[hackney, request, stop], _, #{status := undefined} = Metadata} ->
            false = maps:is_key(error, Metadata)
    after 100 -> ct:fail(async_stop_not_received)
    end.

emits_exception_for_request_that_raises(_Config) ->
    catch hackney_telemetry:call(request([]), fun(_) -> error(boom) end),
    receive
        {[hackney, request, exception], #{duration := _}, Metadata} ->
            #{kind := error, reason := boom, host := <<"api.example.com">>} = Metadata
    after 100 -> ct:fail(exception_not_received)
    end.

emits_checkout_timeout(_Config) ->
    hackney_telemetry:call(request([{pool, stripe}]), fun(_) -> {error, checkout_timeout} end),
    receive
        {[hackney, checkout_timeout], Measurements, Metadata} ->
            #{count := 1} = Measurements,
            #{pool := stripe, host := <<"api.example.com">>} = Metadata
    after 100 -> ct:fail(checkout_timeout_not_received)
    end.

passes_through_before_install(_Config) ->
    Counters = persistent_term:get({hackney_telemetry, counters}),
    persistent_term:erase({hackney_telemetry, counters}),
    try
        {ok, 200, [], <<>>} = hackney_telemetry:call(request([]), fun(_) ->
            {ok, 200, [], <<>>}
        end),
        ok = hackney_telemetry:report(),
        receive
            {[hackney | _], _, _} = Event -> ct:fail({unexpected_event, Event})
        after 0 -> ok
        end
    after
        persistent_term:put({hackney_telemetry, counters}, Counters)
    end.

%% Pools

reports_pool_stats(_Config) ->
    Pool = unique_pool(),
    ok = hackney_pool:start_pool(Pool, [{max_connections, 7}]),
    try
        ok = hackney_telemetry:report(),
        receive
            {[hackney_pool], #{max := 7, in_use_count := 0, free_count := 0}, #{pool := Pool}} ->
                ok
        after 100 -> ct:fail(pool_stats_not_received)
        end
    after
        hackney_pool:stop_pool(Pool)
    end.

skips_pool_that_stopped(_Config) ->
    Pool = unique_pool(),
    {Pid, Ref} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    end,
    true = ets:insert(hackney_pool, {Pool, Pid}),
    try
        ok = hackney_telemetry:report(),
        receive
            {[hackney_pool | _], _, #{pool := Pool}} = Event -> ct:fail({unexpected_event, Event})
        after 0 -> ok
        end
    after
        ets:delete(hackney_pool, Pool)
    end.

reports_pool_stats_timeout(_Config) ->
    Pool = unique_pool(),
    Pid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    true = ets:insert(hackney_pool, {Pool, Pid}),
    try
        ok = hackney_telemetry:report(),
        receive
            {[hackney_pool, stats_timeout], #{count := 1}, #{pool := Pool}} -> ok
        after 100 -> ct:fail(stats_timeout_not_received)
        end
    after
        ets:delete(hackney_pool, Pool),
        Pid ! stop
    end.

%% Reporter

reporter_reports_periodically(_Config) ->
    {ok, Pid} = gen_server:start(hackney_telemetry_reporter, 10, []),
    try
        receive
            {[hackney], #{total_requests := _}, _} -> ok
        after 200 -> ct:fail(report_not_received)
        end
    after
        gen_server:stop(Pid)
    end.

reporter_with_zero_interval_does_not_report(_Config) ->
    {ok, Pid} = gen_server:start(hackney_telemetry_reporter, 0, []),
    try
        ok = gen_server:call(Pid, unexpected),
        ok = gen_server:cast(Pid, unexpected),
        Pid ! unexpected,
        true = is_process_alive(Pid),
        receive
            {[hackney], _, _} = Event -> ct:fail({unexpected_event, Event})
        after 50 -> ok
        end
    after
        gen_server:stop(Pid)
    end.

%% Helpers

send_to_self(Event, Measurements, Metadata, TestPid) ->
    TestPid ! {Event, Measurements, Metadata},
    ok.

other_middleware(Request, Next) ->
    Next(Request).

request(Options) ->
    #{
        method => post,
        url => hackney_url:parse_url(<<"https://api.example.com/charges">>),
        headers => [],
        body => <<>>,
        options => Options
    }.

request_counts() ->
    ok = hackney_telemetry:report(),
    receive
        {[hackney], Measurements, #{}} -> Measurements
    after 100 -> ct:fail(request_counts_not_received)
    end.

unique_pool() ->
    list_to_atom("hackney_telemetry_" ++ integer_to_list(erlang:unique_integer([positive]))).
