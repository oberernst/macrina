defmodule Macrina.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Macrina.CoAP

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: Macrina.Worker.start_link(arg)
      # {Macrina.Worker, arg}
      {DynamicSupervisor, name: CoAP.ConnectionSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: CoAP.ConnectionRegistry},
      {CoAP.Endpoint, 7150}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Macrina.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
