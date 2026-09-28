-module(hackney_telemetry_SUITE).

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
        passes_through_while_application_is_stopped,
        returns_response_when_application_stops_mid_request,
        counts_requests_made_through_hackney,
        counts_request_as_in_flight_until_it_finishes,
        counts_request_that_raises_as_finished,
        finishes_requests_of_killed_processes,
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
    ok = hackney_telemetry:install(),
    {ok, [Middleware, Other]} = application:get_env(hackney, middleware),
    Middleware = fun hackney_telemetry:call/2.

uninstall_keeps_other_middleware(_Config) ->
    Other = fun ?MODULE:other_middleware/2,
    application:set_env(hackney, middleware, [fun hackney_telemetry:call/2, Other]),
    ok = hackney_telemetry:uninstall(),
    {ok, [Other]} = application:get_env(hackney, middleware),
    application:set_env(hackney, middleware, [fun hackney_telemetry:call/2]),
    ok = hackney_telemetry:uninstall(),
    undefined = application:get_env(hackney, middleware).

passes_through_while_application_is_stopped(_Config) ->
    ok = application:stop(hackney_telemetry),
    try
        {ok, 200, [], <<>>} = hackney_telemetry:call(request([]), fun(_) ->
            {ok, 200, [], <<>>}
        end),
        receive
            {[hackney | _], _, _} = Event -> ct:fail({unexpected_event, Event})
        after 50 -> ok
        end
    after
        ok = application:start(hackney_telemetry)
    end.

returns_response_when_application_stops_mid_request(_Config) ->
    Self = self(),
    Caller = spawn(fun() ->
        Response = hackney_telemetry:call(request([]), fun(_) ->
            Self ! started,
            receive
                continue -> {ok, 200, [], <<>>}
            end
        end),
        Self ! {response, Response}
    end),
    receive
        started -> ok
    end,
    ok = application:stop(hackney_telemetry),
    try
        Caller ! continue,
        receive
            {response, Response} -> {ok, 200, [], <<>>} = Response
        after 100 -> ct:fail(response_not_received)
        end
    after
        ok = application:start(hackney_telemetry)
    end.

%% Counters

counts_requests_made_through_hackney(_Config) ->
    {error, _Reason} = hackney:request(get, <<"http://127.0.0.1:1">>, [], <<>>, []),
    receive_measurement(total_requests),
    receive_measurement(finished_requests).

counts_request_as_in_flight_until_it_finishes(_Config) ->
    Before = in_flight(),
    {ok, 200, [], <<>>} = hackney_telemetry:call(request([]), fun(_) ->
        InFlight = Before + 1,
        InFlight = in_flight(),
        {ok, 200, [], <<>>}
    end),
    Before = in_flight().

counts_request_that_raises_as_finished(_Config) ->
    Before = in_flight(),
    {'EXIT', {boom, _}} =
        (catch hackney_telemetry:call(request([]), fun(_) -> error(boom) end)),
    receive_measurement(finished_requests),
    Before = in_flight().

finishes_requests_of_killed_processes(_Config) ->
    Before = in_flight(),
    Self = self(),
    Pids = [
        spawn(fun() ->
            hackney_telemetry:call(request([]), fun(_) ->
                Self ! started,
                timer:sleep(infinity)
            end)
        end)
     || _ <- [1, 2]
    ],
    [
        receive
            started -> ok
        end
     || _ <- Pids
    ],
    InFlight = Before + 2,
    InFlight = in_flight(),
    [Shutdown, Kill] = Pids,
    exit(Shutdown, shutdown),
    exit(Kill, kill),
    wait_until_dead(Pids),
    flush(),
    Before = in_flight(),
    receive
        {[hackney], #{finished_requests := _}, #{}} -> ok
    after 100 -> ct:fail(finished_requests_not_received)
    end.

%% Span

emits_request_span(_Config) ->
    hackney_telemetry:call(request([{pool, stripe}]), fun(_) ->
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
    hackney_telemetry:call(request([{pool, stripe}]), fun(_) ->
        {error, checkout_timeout}
    end),
    receive
        {[hackney, checkout_timeout], Measurements, Metadata} ->
            #{count := 1} = Measurements,
            #{pool := stripe, host := <<"api.example.com">>} = Metadata
    after 100 -> ct:fail(checkout_timeout_not_received)
    end.

tags_request_without_pool_as_none(_Config) ->
    hackney_telemetry:call(request([{pool, false}]), fun(_) -> {ok, 200, [], <<>>} end),
    receive
        {[hackney, request, stop], _, #{pool := none}} -> ok
    after 100 -> ct:fail(stop_not_received)
    end,
    application:set_env(hackney, use_default_pool, false),
    try
        hackney_telemetry:call(request([]), fun(_) -> {ok, 200, [], <<>>} end),
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

% Poll, then take the last nb_requests reported, which is from this poll or a
% later one.
in_flight() ->
    flush(),
    ok = hackney_telemetry_pool_poller:poll(),
    last_in_flight(undefined).

last_in_flight(Value) ->
    receive
        {[hackney], #{nb_requests := NewValue}, #{}} -> last_in_flight(NewValue)
    after 50 ->
        Value =/= undefined orelse ct:fail(nb_requests_not_received),
        Value
    end.

flush() ->
    receive
        {[hackney], _, _} -> flush()
    after 0 -> ok
    end.

wait_until_dead(Pids) ->
    case lists:any(fun erlang:is_process_alive/1, Pids) of
        true ->
            timer:sleep(1),
            wait_until_dead(Pids);
        false ->
            ok
    end.

receive_measurement(Key) ->
    receive
        {[hackney], #{Key := Value}, #{}} -> Value
    after 100 -> ct:fail({measurement_not_received, Key})
    end.
