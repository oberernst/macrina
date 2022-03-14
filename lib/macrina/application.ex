defmodule Macrina.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: Macrina.Worker.start_link(arg)
      # {Macrina.Worker, arg}
      {DynamicSupervisor, name: Macrina.ConnectionSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Macrina.RequestSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Macrina.ConnectionRegistry}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Macrina.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
