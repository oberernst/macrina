defmodule Macrina.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: Macrina.ConnectionSupervisor, strategy: :one_for_one},
      Macrina.BlockTransfer.Supervisor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Macrina.Supervisor]
    res = Supervisor.start_link(children, opts)
    Logger.info("[Macrina] started", result: inspect(res))
    res
  end
end
