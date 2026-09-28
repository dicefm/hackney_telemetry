%%% @doc hackney_telemetry application supervisor.
%%% @end

-module(hackney_telemetry_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, ReportInterval} = application:get_env(hackney_telemetry, report_interval),
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 5},
    {ok, {SupFlags, child_specs(ReportInterval)}}.

child_specs(0) ->
    [];
child_specs(ReportInterval) ->
    [
        #{
            id => hackney_telemetry_reporter,
            start => {hackney_telemetry_reporter, start_link, [ReportInterval]}
        }
    ].
