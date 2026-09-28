%%% @doc Calls `hackney_telemetry:report/0' every `ReportInterval' milliseconds.
%%%
%%% The next report is scheduled once the current one finishes, so a slow pool
%%% delays reports instead of piling them up. An interval of 0 disables it.
%%% @end

-module(hackney_telemetry_reporter).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link(non_neg_integer()) -> gen_server:start_ret().
start_link(ReportInterval) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, ReportInterval, []).

init(ReportInterval) ->
    schedule(ReportInterval),
    {ok, ReportInterval}.

handle_call(_Request, _From, ReportInterval) ->
    {reply, ok, ReportInterval}.

handle_cast(_Request, ReportInterval) ->
    {noreply, ReportInterval}.

handle_info(report, ReportInterval) ->
    hackney_telemetry:report(),
    schedule(ReportInterval),
    {noreply, ReportInterval};
handle_info(_Message, ReportInterval) ->
    {noreply, ReportInterval}.

schedule(0) ->
    ok;
schedule(ReportInterval) ->
    erlang:send_after(ReportInterval, self(), report),
    ok.
