defmodule Macrina.Telemetry do
  @moduledoc """
  Telemetry integration.

  Thin wrapper around `:telemetry` that prefixes all event names with
  `[:macrina]`. Every counter and span the library emits flows through
  this module.

  ## Event catalogue (1.0)

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:macrina, :app, :start]` | `system_time` | `result` |
  | `[:macrina, :endpoint, :start]` | `system_time` | `port` |
  | `[:macrina, :endpoint, :udp, :error]` | `count` | `reason` |
  | `[:macrina, :endpoint, :packet, :received]` | `bytes` | `peer`, `ip`, `port` |
  | `[:macrina, :endpoint, :connection, :start, :error]` | `count` | `error`, `peer` |
  | `[:macrina, :connection, :start]` | `system_time` | `ip`, `peer`, `port` |
  | `[:macrina, :connection, :stop]` | `system_time` | `ip`, `peer`, `port` |
  | `[:macrina, :connection, :request, :encode, :error]` | `count` | `error`, `ip`, `peer`, `port` |
  | `[:macrina, :connection, :reply, :skipped]` | `count` | `stage` |
  | `[:macrina, :connection, :decode, :error]` | `count` | `reason` |
  | `[:macrina, :connection, :block, :received]` | `block_number`, `block_size`, `bytes` | `more` |
  | `[:macrina, :connection, :block, :assembled]` | `bytes`, `count` | `first_block`, `last_block` |
  | `[:macrina, :connection, :block, :missing]` | `count` | `missing_block`, `received_blocks` |
  | `[:macrina, :connection, :block, :completed]` | `bytes`, `count` | `code`, `type` |
  | `[:macrina, :connection, :block, :continue]` | `count` | varies |
  | `[:macrina, :connection, :incomplete_transfer]` | `count` | varies |
  | `[:macrina, :exchange, :dedup, :hit]` | `count` | `cached`, `code`, `id`, `ip`, `peer`, `port` |
  | `[:macrina, :exchange, :retransmit]` | `attempt`, `bytes`, `count` | `id`, `ip`, `peer`, `port`, `token` |
  | `[:macrina, :exchange, :timeout]` | `count`, `retransmissions` | `id`, `ip`, `peer`, `port`, `token`, optionally `phase` |
  | `[:macrina, :observe, :register]` | `count` | `path`, `token` |
  | `[:macrina, :observe, :cancel]` | `count` | `path`, `token` |

  All event names go through `Macrina.Telemetry.event_name/1`, which
  prepends `[:macrina]`. Attach handlers with the prefixed name.

  This catalogue is part of the 1.0 surface — additions are
  non-breaking; renames or removals are breaking and will be
  documented in `CHANGELOG.md`.
  """
  @prefix [:macrina]

  def prefix, do: @prefix

  def event_name(parts) when is_list(parts) do
    @prefix ++ parts
  end

  def execute(parts, measurements, metadata \\ %{})
      when is_list(parts) and is_map(measurements) do
    :telemetry.execute(event_name(parts), measurements, metadata)
  end

  def span(parts, start_metadata, fun) when is_list(parts) and is_map(start_metadata) do
    :telemetry.span(event_name(parts), start_metadata, fun)
  end
end
