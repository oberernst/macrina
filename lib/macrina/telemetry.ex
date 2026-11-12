defmodule Macrina.Telemetry do
  @moduledoc """
  Telemetry integration.

  Thin wrapper around `:telemetry` that prefixes all event names with
  `[:macrina]`. Every counter and span the library emits flows through
  this module.

  ## Event catalogue (1.0)

  - `[:macrina, :app, :start]`: measurements `system_time`, metadata `result`.

  - `[:macrina, :endpoint, :start]`: measurements `system_time`, metadata `port`.

  - `[:macrina, :endpoint, :udp, :error]`: measurements `count`, metadata `reason`.

  - `[:macrina, :endpoint, :packet, :received]`: measurements `bytes`, metadata `peer`, `ip`, `port`.

  - `[:macrina, :endpoint, :connection, :start, :error]`: measurements `count`, metadata `error`, `peer`.

  - `[:macrina, :connection, :start]`: measurements `system_time`, metadata `ip`, `peer`, `port`.

  - `[:macrina, :connection, :stop]`: measurements `system_time`, metadata `ip`, `peer`, `port`.

  - `[:macrina, :connection, :request, :encode, :error]`: measurements `count`, metadata `error`, `ip`, `peer`, `port`.

  - `[:macrina, :connection, :reply, :skipped]`: measurements `count`, metadata `stage`.

  - `[:macrina, :connection, :decode, :error]`: measurements `count`, metadata `reason`.

  - `[:macrina, :connection, :block, :received]`: measurements `block_number`, `block_size`, `bytes`, metadata `more`.

  - `[:macrina, :connection, :block, :assembled]`: measurements `bytes`, `count`, metadata `first_block`, `last_block`.

  - `[:macrina, :connection, :block, :missing]`: measurements `count`, metadata `missing_block`, `received_blocks`.

  - `[:macrina, :connection, :block, :completed]`: measurements `bytes`, `count`, metadata `code`, `type`.

  - `[:macrina, :connection, :block, :continue]`: measurements `count`, metadata varies.

  - `[:macrina, :connection, :incomplete_transfer]`: measurements `count`, metadata varies.

  - `[:macrina, :exchange, :dedup, :hit]`: measurements `count`, metadata `cached`, `code`, `id`, `ip`, `peer`, `port`.

  - `[:macrina, :exchange, :retransmit]`: measurements `attempt`, `bytes`, `count`, metadata `id`, `ip`, `peer`, `port`, `token`.

  - `[:macrina, :exchange, :timeout]`: measurements `count`, `retransmissions`, metadata `id`, `ip`, `peer`, `port`, `token`, optionally `phase`.

  - `[:macrina, :observe, :register]`: measurements `count`, metadata `path`, `token`.

  - `[:macrina, :observe, :cancel]`: measurements `count`, metadata `path`, `token`.


  All event names go through `Macrina.Telemetry.event_name/1`, which
  prepends `[:macrina]`. Attach handlers with the prefixed name.

  This catalogue is part of the 1.0 surface. Additions are non-breaking.
  Renames and removals are breaking and are documented in `CHANGELOG.md`.
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
