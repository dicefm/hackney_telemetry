![Tests](https://github.com/msramos/hackney_telemetry/actions/workflows/ci.yml/badge.svg)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)

> [!IMPORTANT]
> This is the new upstream of this project. The [TheRealReal](https://github.com/TheRealReal/hackney_telemetry) repository will no longer be mantained.

# hackney_telemetry

Telemetry for the [Hackney](https://github.com/benoitc/hackney) HTTP client.

Requires hackney 4. Hackney 4 no longer emits metrics itself and expects them
to come from a [middleware](https://hackney.hexdocs.pm/middleware.html) and
from `hackney_pool:get_stats/1`. This library is both: when its application
starts it adds a middleware to hackney's global chain and starts a reporter
that polls every pool.

For hackney 1.x use version 0.2.0, which plugs into hackney's `mod_metrics`.

## Telemetry events

| Event | Measurements | Metadata | Emitted |
| ----- | ------------ | -------- | ------- |
| `[hackney, request, start]` | `system_time`, `monotonic_time` | `method`, `host`, `pool` | When a request starts |
| `[hackney, request, stop]` | `duration`, `monotonic_time` | `method`, `host`, `pool`, `status`, `error` | When a request returns |
| `[hackney, request, exception]` | `duration`, `monotonic_time` | `method`, `host`, `pool`, `kind`, `reason`, `stacktrace` | When a request raises |
| `[hackney, checkout_timeout]` | `count` | `host`, `pool` | When a request gets `{error, checkout_timeout}` |
| `[hackney]` | `nb_requests`, `total_requests`, `finished_requests` | - | Every report interval |
| `[hackney_pool]` | `max`, `in_use_count`, `free_count` | `pool` | Every report interval, for each pool |
| `[hackney_pool, stats_timeout]` | `count` | `pool` | When a pool doesn't answer `get_stats/1` in time |

`status` is `undefined` when the request returned an error, or `{ok, Ref}` for
an async or streaming request. `error` is only set for errors.

- `nb_requests` counts requests in flight, `total_requests` the requests
  started and `finished_requests` the ones that returned or raised. Async and
  streaming requests finish when hackney returns, before the body is read.
  Each redirect hackney follows counts as a request.
- `max` is the pool's `max_connections`. In hackney 4 it bounds the idle
  connections kept in the pool, not the connections in use, so `in_use_count`
  can go above it.
- `checkout_timeout` means the host reached its `max_per_host` connections,
  or the pool didn't answer in time.

### Metrics from 0.2.0

`nb_requests`, `total_requests`, `finished_requests`, `in_use_count` and
`free_count` keep their names. The pool counts are now sampled every report
interval instead of updated on every checkout. Hackney 4 can't provide the
rest:

- `queue_count`: hackney 4 pools don't queue. `checkout_timeout` is the
  closest signal.
- `take_rate` and `no_socket`: hackney 4 has no hook that tells a reused
  connection from a new one.

## Installation

Add it to your dependencies and make sure the `hackney_telemetry` application
starts. Nothing else needs configuring.

Requests that set their own `middleware` option replace the global chain, so
they are not counted.

## Configuration

`report_interval` sets how often the reporter runs, in milliseconds. It
defaults to 1000. Set it to 0 to disable the reporter.

**Erlang**

```erlang
{hackney_telemetry, [{report_interval, 2000}]}
```

**Elixir**

```elixir
config :hackney_telemetry, report_interval: 2_000
```

## Usage

Handle the events in your application, or use a reporter such as
[Telemetry.Metrics](https://hex.pm/packages/telemetry_metrics):

```elixir
defmodule YourApplication.Telemetry do
  import Telemetry.Metrics

  def metrics do
    [
      last_value("hackney.nb_requests"),
      last_value("hackney.finished_requests"),
      last_value("hackney.total_requests"),
      last_value("hackney_pool.max", tags: [:pool]),
      last_value("hackney_pool.in_use_count", tags: [:pool]),
      last_value("hackney_pool.free_count", tags: [:pool]),
      counter("hackney_pool.stats_timeout.count", tags: [:pool]),
      counter("hackney.checkout_timeout.count", tags: [:host, :pool]),
      counter("hackney.request.exception.duration", tags: [:host, :pool]),
      distribution("hackney.request.stop.duration",
        unit: {:native, :millisecond},
        tags: [:host, :pool, :status]
      )
    ]
  end
end
```

Don't use `error`, `reason` or `stacktrace` as tags: they have unbounded values.

## Building

To build the source code locally you'll need [rebar3](https://github.com/erlang/rebar3):

```
rebar3 compile
```

## Test

```console
rebar3 ct
```

## Docs

```console
rebar3 ex_doc
```

## Format code

```console
rebar3 format
```

## Code of Conduct

This project  Contributor Covenant version 2.1. Check [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) file for more information.

## License

`hackney_telemetry` source code is released under Apache License 2.0.

Check [NOTICE](NOTICE) and [LICENSE](LICENSE) files for more information.
