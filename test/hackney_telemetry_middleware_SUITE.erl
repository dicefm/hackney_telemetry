-module(hackney_telemetry_middleware_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-define(EVENTS, [
    [hackney],
    [hackney, request, start],
    [hackney, request, stop],
    [hackney, request, exception],
    [hackney, checkout_timeout]
]).

all() ->
    [
        installs_middleware_on_start,
        install_keeps_other_middleware,
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
        tags_request_without_pool_as_none
    ].

init_per_suite(Config) ->
    % Report on every update, so each counter change emits an event.
    _ = application:load(hackney_telemetry),
    ok = application:set_env(hackney_telemetry, report_interval, 0),
    {ok, _} = application:ensure_all_started(hackney_telemetry),
    Config.

end_per_suite(Config) ->
    application:stop(hackney_telemetry),
    application:unload(hackney_telemetry),
    Config.

init_per_testcase(_TestCase, Config) ->
    ok = telemetry:attach_many(?MODULE, ?EVENTS, fun ?MODULE:send_to_self/4, self()),
    Config.

end_per_testcase(_TestCase, Config) ->
    telemetry:detach(?MODULE),
    application:set_env(hackney, middleware, [fun hackney_telemetry_middleware:call/2]),
    Config.

%% Install

installs_middleware_on_start(_Config) ->
    {ok, [Middleware]} = application:get_env(hackney, middleware),
    Middleware = fun hackney_telemetry_middleware:call/2.

install_keeps_other_middleware(_Config) ->
    Other = fun ?MODULE:other_middleware/2,
    application:set_env(hackney, middleware, [Other]),
    ok = hackney_telemetry_middleware:install(),
    ok = hackney_telemetry_middleware:install(),
    {ok, [Middleware, Other]} = application:get_env(hackney, middleware),
    Middleware = fun hackney_telemetry_middleware:call/2.

uninstall_keeps_other_middleware(_Config) ->
    Other = fun ?MODULE:other_middleware/2,
    application:set_env(hackney, middleware, [fun hackney_telemetry_middleware:call/2, Other]),
    ok = hackney_telemetry_middleware:uninstall(),
    {ok, [Other]} = application:get_env(hackney, middleware),
    application:set_env(hackney, middleware, [fun hackney_telemetry_middleware:call/2]),
    ok = hackney_telemetry_middleware:uninstall(),
    undefined = application:get_env(hackney, middleware).

stopping_the_application_removes_middleware(_Config) ->
    ok = application:stop(hackney_telemetry),
    undefined = application:get_env(hackney, middleware),
    ok = application:start(hackney_telemetry),
    {ok, [_]} = application:get_env(hackney, middleware).

%% Counters

counts_requests_made_through_hackney(_Config) ->
    {error, _Reason} = hackney:request(get, <<"http://127.0.0.1:1">>, [], <<>>, []),
    receive_measurement(total_requests),
    receive_measurement(finished_requests).

counts_request_as_in_flight_until_it_finishes(_Config) ->
    {ok, 200, [], <<>>} = hackney_telemetry_middleware:call(request([]), fun(_) ->
        {ok, 200, [], <<>>}
    end),
    InFlight = receive_measurement(nb_requests),
    Finished = InFlight - 1,
    Finished = receive_measurement(nb_requests).

counts_request_that_raises_as_finished(_Config) ->
    {'EXIT', {boom, _}} =
        (catch hackney_telemetry_middleware:call(request([]), fun(_) -> error(boom) end)),
    InFlight = receive_measurement(nb_requests),
    Finished = InFlight - 1,
    Finished = receive_measurement(nb_requests),
    receive_measurement(finished_requests).

%% Span

emits_request_span(_Config) ->
    hackney_telemetry_middleware:call(request([{pool, stripe}]), fun(_) ->
        {ok, 201, [], <<"body">>}
    end),
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
    hackney_telemetry_middleware:call(request([]), fun(_) -> {error, timeout} end),
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
    hackney_telemetry_middleware:call(request([]), fun(_) -> {ok, 204, []} end),
    receive
        {[hackney, request, stop], _, #{status := 204}} -> ok
    after 100 -> ct:fail(head_stop_not_received)
    end,
    hackney_telemetry_middleware:call(request([]), fun(_) -> {ok, make_ref()} end),
    receive
        {[hackney, request, stop], _, #{status := undefined} = Metadata} ->
            false = maps:is_key(error, Metadata)
    after 100 -> ct:fail(async_stop_not_received)
    end.

emits_exception_for_request_that_raises(_Config) ->
    catch hackney_telemetry_middleware:call(request([]), fun(_) -> error(boom) end),
    receive
        {[hackney, request, exception], #{duration := _}, Metadata} ->
            #{kind := error, reason := boom, host := <<"api.example.com">>} = Metadata
    after 100 -> ct:fail(exception_not_received)
    end.

emits_checkout_timeout(_Config) ->
    hackney_telemetry_middleware:call(request([{pool, stripe}]), fun(_) ->
        {error, checkout_timeout}
    end),
    receive
        {[hackney, checkout_timeout], Measurements, Metadata} ->
            #{count := 1} = Measurements,
            #{pool := stripe, host := <<"api.example.com">>} = Metadata
    after 100 -> ct:fail(checkout_timeout_not_received)
    end.

tags_request_without_pool_as_none(_Config) ->
    hackney_telemetry_middleware:call(request([{pool, false}]), fun(_) -> {ok, 200, [], <<>>} end),
    receive
        {[hackney, request, stop], _, #{pool := none}} -> ok
    after 100 -> ct:fail(stop_not_received)
    end,
    application:set_env(hackney, use_default_pool, false),
    try
        hackney_telemetry_middleware:call(request([]), fun(_) -> {ok, 200, [], <<>>} end),
        receive
            {[hackney, request, stop], _, #{pool := none}} -> ok
        after 100 -> ct:fail(stop_not_received)
        end
    after
        application:unset_env(hackney, use_default_pool)
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

receive_measurement(Key) ->
    receive
        {[hackney], #{Key := Value}, #{}} -> Value
    after 100 -> ct:fail({measurement_not_received, Key})
    end.
