%%% @doc Telemetry for hackney requests and connection pools.
%%%
%%% When the application starts it adds `call/2' to hackney's global
%%% middleware chain and starts a reporter that calls `report/0' every
%%% `report_interval' milliseconds.
%%%
%%% The middleware wraps every `hackney:request/1..5' in a
%%% `[hackney, request]' span, counts requests, and emits
%%% `[hackney, checkout_timeout]' when a request gets
%%% `{error, checkout_timeout}'.
%%%
%%% `report/0' emits the request counts as `[hackney]' and the stats of each
%%% pool as `[hackney_pool]'. Each pool is polled in its own process, so a
%%% stuck pool doesn't delay the others. When a pool doesn't answer in time it
%%% emits `[hackney_pool, stats_timeout]' instead.
%%% @end

-module(hackney_telemetry).

-export([install/0, uninstall/0, call/2, report/0]).

-include_lib("hackney/include/hackney_lib.hrl").

-define(COUNTERS, {?MODULE, counters}).
-define(TOTAL, 1).
-define(FINISHED, 2).

%% @doc Add the middleware to the front of hackney's global chain.
%%
%% Middleware already in the chain is kept. Calling it again changes nothing.
%% @end
-spec install() -> ok.
install() ->
    case persistent_term:get(?COUNTERS, undefined) of
        undefined -> persistent_term:put(?COUNTERS, counters:new(2, [write_concurrency]));
        _Counters -> ok
    end,
    application:set_env(hackney, middleware, [middleware() | other_middleware()]).

%% @doc Remove the middleware from hackney's global chain.
-spec uninstall() -> ok.
uninstall() ->
    case other_middleware() of
        [] -> application:unset_env(hackney, middleware);
        Chain -> application:set_env(hackney, middleware, Chain)
    end.

%% @doc The hackney middleware. See `hackney_middleware'.
%%
%% Requests pass through untouched until `install/0' has run.
%% @end
-spec call(hackney_middleware:request(), hackney_middleware:next()) ->
    hackney_middleware:response().
call(Request, Next) ->
    case persistent_term:get(?COUNTERS, undefined) of
        undefined -> Next(Request);
        Counters -> count(Counters, Request, Next)
    end.

%% @doc Emit the request counts and the stats of every hackney pool.
%%
%% The request counts are emitted before it returns. Pool stats are emitted
%% from one process per pool, which may finish after it returns.
%% @end
-spec report() -> ok.
report() ->
    report_requests(),
    lists:foreach(
        fun(Pool) -> proc_lib:spawn(fun() -> report_pool(Pool) end) end,
        pools()
    ).

%% Internal

middleware() ->
    fun ?MODULE:call/2.

other_middleware() ->
    case application:get_env(hackney, middleware) of
        {ok, Chain} when is_list(Chain) -> lists:delete(middleware(), Chain);
        _ -> []
    end.

count(Counters, Request, Next) ->
    counters:add(Counters, ?TOTAL, 1),
    try
        span(Request, Next)
    after
        counters:add(Counters, ?FINISHED, 1)
    end.

span(#{method := Method, url := #hackney_url{host = Host}, options := Options} = Request, Next) ->
    Metadata = #{method => Method, host => list_to_binary(Host), pool => pool(Options)},
    telemetry:span([hackney, request], Metadata, fun() ->
        Response = Next(Request),
        Response =:= {error, checkout_timeout} andalso
            telemetry:execute(
                [hackney, checkout_timeout], #{count => 1}, maps:remove(method, Metadata)
            ),
        {Response, maps:merge(Metadata, response_metadata(Response))}
    end).

% Same rules hackney uses to pick the pool of a request.
pool(Options) ->
    case proplists:get_value(pool, Options) of
        false ->
            none;
        undefined ->
            case application:get_env(hackney, use_default_pool, true) of
                false -> none;
                _ -> default
            end;
        Pool ->
            Pool
    end.

response_metadata({ok, Status, _Headers, _Body}) ->
    #{status => Status};
response_metadata({ok, Status, _Headers}) ->
    #{status => Status};
response_metadata({error, Reason}) ->
    #{status => undefined, error => Reason};
response_metadata(_Async) ->
    #{status => undefined}.

report_requests() ->
    case persistent_term:get(?COUNTERS, undefined) of
        undefined ->
            ok;
        Counters ->
            % Read finished first so nb_requests can't go negative.
            Finished = counters:get(Counters, ?FINISHED),
            Total = counters:get(Counters, ?TOTAL),
            telemetry:execute(
                [hackney],
                #{
                    nb_requests => Total - Finished,
                    total_requests => Total,
                    finished_requests => Finished
                },
                #{}
            )
    end.

% hackney has no function that lists pools, so read the table it keeps them in.
pools() ->
    try ets:tab2list(hackney_pool) of
        Entries -> [Pool || {Pool, _Pid} <- Entries]
    catch
        error:badarg -> []
    end.

report_pool(Pool) ->
    try hackney_pool:get_stats(Pool) of
        Stats ->
            telemetry:execute(
                [hackney_pool],
                #{
                    max => proplists:get_value(max, Stats),
                    in_use_count => proplists:get_value(in_use_count, Stats),
                    free_count => proplists:get_value(free_count, Stats)
                },
                #{pool => Pool}
            )
    catch
        exit:{timeout, _} ->
            telemetry:execute([hackney_pool, stats_timeout], #{count => 1}, #{pool => Pool});
        % The pool stopped after it was listed.
        exit:_ ->
            ok
    end.
