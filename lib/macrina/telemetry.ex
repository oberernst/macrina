defmodule Macrina.Telemetry do
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
