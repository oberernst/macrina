defmodule Macrina.Application do
  @moduledoc false

  use Application
  alias Macrina.Telemetry

  @impl true
  def start(_type, _args) do
    children = [
      {Macrina.Observe, []},
      {DynamicSupervisor, name: Macrina.ConnectionSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Macrina.Supervisor]
    res = Supervisor.start_link(children, opts)
    Telemetry.execute([:app, :start], %{system_time: System.system_time()}, %{result: res})
    res
  end
end
