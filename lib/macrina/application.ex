defmodule Macrina.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: Macrina.Worker.start_link(arg)
      # {Macrina.Worker, arg}
      {DynamicSupervisor, name: Macrina.ConnectionSupervisor, strategy: :one_for_one}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Macrina.Supervisor]
    res = Supervisor.start_link(children, opts)
    Logger.info("macrina started", result: inspect(res))
    res
  end
end
