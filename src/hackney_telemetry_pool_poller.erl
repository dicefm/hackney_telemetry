%%% @doc Polls the stats of every hackney pool.
%%%
%%% Hackney 4 no longer calls a `mod_metrics' module, so this process reads
%%% `hackney_pool:get_stats/1' and updates the pool metrics that hackney used
%%% to update:
%%%
%%% - [hackney_pool, PoolName, max]
%%% - [hackney_pool, PoolName, in_use_count]
%%% - [hackney_pool, PoolName, free_count]
%%%
%%% It starts a worker for each metric of a new pool and stops them once the
%%% pool is gone. Each pool is polled in its own process, so a pool that
%%% doesn't answer doesn't delay the others. When a pool doesn't answer in time
%%% it emits `[hackney_pool, stats_timeout]'.
%%%
%%% On each poll it also calls `hackney_telemetry_middleware:sweep/0'.
%%%
%%% It polls every `report_interval' milliseconds, or every second when
%%% `report_interval' is 0.
%%% @end

-module(hackney_telemetry_pool_poller).

-behaviour(gen_server).

-export([start_link/0, child_spec/0, poll/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MEASUREMENTS, [max, in_use_count, free_count]).
-define(DEFAULT_POLL_INTERVAL, 1000).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Poll the pools now.

-spec poll() -> ok.
poll() ->
    gen_server:call(?MODULE, poll).

init([]) ->
    schedule(),
    {ok, []}.

handle_call(poll, _From, Pools) ->
    {reply, ok, poll(Pools)};
handle_call(_Message, _From, Pools) ->
    {reply, ok, Pools}.

handle_cast(_Message, Pools) ->
    {noreply, Pools}.

handle_info(poll, Pools) ->
    schedule(),
    {noreply, poll(Pools)};
handle_info(_Message, Pools) ->
    {noreply, Pools}.

poll(KnownPools) ->
    hackney_telemetry_middleware:sweep(),
    Pools = pools(),
    lists:foreach(
        fun(Pool) -> for_each_metric(Pool, fun hackney_telemetry:delete/1) end, KnownPools -- Pools
    ),
    lists:foreach(
        fun(Pool) ->
            for_each_metric(Pool, fun(Metric) -> hackney_telemetry:new(gauge, Metric) end)
        end,
        Pools -- KnownPools
    ),
    lists:foreach(fun(Pool) -> proc_lib:spawn(fun() -> update(Pool) end) end, Pools),
    Pools.

% hackney has no function that lists pools, so read the table it keeps them in.
% Only pools named by an atom get metrics, as in hackney_telemetry:new/2.
pools() ->
    try ets:tab2list(hackney_pool) of
        Entries -> [Pool || {Pool, _Pid} <- Entries, is_atom(Pool)]
    catch
        error:badarg -> []
    end.

for_each_metric(Pool, Fun) ->
    lists:foreach(fun(Measurement) -> Fun([hackney_pool, Pool, Measurement]) end, ?MEASUREMENTS).

update(Pool) ->
    try hackney_pool:get_stats(Pool) of
        Stats ->
            lists:foreach(
                fun(Measurement) ->
                    Value = proplists:get_value(Measurement, Stats),
                    hackney_telemetry:update_gauge([hackney_pool, Pool, Measurement], Value)
                end,
                ?MEASUREMENTS
            )
    catch
        exit:{timeout, _} ->
            telemetry:execute([hackney_pool, stats_timeout], #{count => 1}, #{pool => Pool});
        % The pool stopped after it was listed.
        exit:_ ->
            ok
    end.

schedule() ->
    Interval =
        case application:get_env(hackney_telemetry, report_interval, 0) of
            0 -> ?DEFAULT_POLL_INTERVAL;
            ReportInterval -> ReportInterval
        end,
    erlang:send_after(Interval, self(), poll).
