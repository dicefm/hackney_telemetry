%%% @doc Hackney middleware that reports request metrics.
%%%
%%% Hackney 4 no longer calls a `mod_metrics' module. This middleware updates
%%% the request counters that hackney used to update:
%%%
%%% - [hackney, nb_requests]
%%% - [hackney, total_requests]
%%% - [hackney, finished_requests]
%%%
%%% It also wraps each request in a `[hackney, request]' span and emits
%%% `[hackney, checkout_timeout]' when a request gets
%%% `{error, checkout_timeout}'.
%%% @end

-module(hackney_telemetry_middleware).

-export([install/0, uninstall/0, call/2]).

-include_lib("hackney/include/hackney_lib.hrl").

%% @doc Add the middleware to the front of hackney's global chain.
%%
%% Middleware already in the chain is kept.
%% @end

-spec install() -> ok.
install() ->
    application:set_env(hackney, middleware, [middleware() | other_middleware()]).

%% @doc Remove the middleware from hackney's global chain.

-spec uninstall() -> ok.
uninstall() ->
    case other_middleware() of
        [] -> application:unset_env(hackney, middleware);
        Chain -> application:set_env(hackney, middleware, Chain)
    end.

%% @doc The hackney middleware. See `hackney_middleware'.

-spec call(hackney_middleware:request(), hackney_middleware:next()) ->
    hackney_middleware:response().
call(Request, Next) ->
    hackney_telemetry:increment_counter([hackney, nb_requests]),
    hackney_telemetry:increment_counter([hackney, total_requests]),
    try
        span(Request, Next)
    after
        hackney_telemetry:decrement_counter([hackney, nb_requests]),
        hackney_telemetry:increment_counter([hackney, finished_requests])
    end.

middleware() ->
    fun ?MODULE:call/2.

other_middleware() ->
    case application:get_env(hackney, middleware) of
        {ok, Chain} when is_list(Chain) -> lists:delete(middleware(), Chain);
        _ -> []
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
