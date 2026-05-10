defmodule Macrina.Server do
  @moduledoc """
  Public entry point for starting a CoAP server.

  Wraps `Macrina.Endpoint` with ergonomic options for handler/router selection,
  Block1 upload policy, and observer notifications.

  ## Starting a server

      {:ok, server} = Macrina.Server.start_link(
        handler: MyApp.CoapHandler,
        port: 5683
      )

  Or with a router and Block1 policy:

      block1 = Macrina.Block1.new!(mode: :streaming, preferred_block_size: 512)

      {:ok, server} = Macrina.Server.start_link(
        router: MyApp.Router,
        port: 5683,
        block1: block1
      )

  ## Options

    * `:handler` — a module exporting `call(connection, message)` that returns
      a `Macrina.Message` reply or `nil` (mutually exclusive with `:router`)
    * `:router` — a module implementing `Macrina.Router` (mutually exclusive with `:handler`)
    * `:context` — an arbitrary map passed to router callbacks (default: `%{}`)
    * `:port` — Endpoint port to bind (required)
    * `:name` — registered name for the endpoint process
    * `:block1` — a `Macrina.Block1` policy struct for upload handling

  ## Pushing notifications

  After starting a server, use `notify/3` to push a response to all clients
  observing a given path:

      {:ok, count} = Macrina.Server.notify(server, "/temperature",
        Macrina.Response.new(:content, payload: "23.1 C")
      )

  Returns `{:ok, count}` where `count` is the number of observers notified.
  """

  alias Macrina.{Endpoint, Observe, Response}
  alias Macrina.Peer.Session

  @doc """
  Starts a CoAP server bound to the given Endpoint port.

  Returns `{:ok, pid}` on success. See module documentation for options.
  """
  def start_link(opts) when is_list(opts) do
    with {:ok, endpoint_opts} <- build_endpoint_opts(opts) do
      Endpoint.start_link(endpoint_opts)
    end
  end

  @doc "Like `start_link/1` but raises on failure."
  def start_link!(opts) when is_list(opts) do
    case start_link(opts) do
      {:ok, pid} -> pid
      {:error, reason} -> raise ArgumentError, "invalid server start options: #{inspect(reason)}"
    end
  end

  @doc """
  Pushes a response to all clients observing `path` on `server`.

  Returns `{:ok, count}` where `count` is the number of observers notified,
  or `{:error, reason}` if the path cannot be resolved.
  """
  def notify(server, path, %Response{} = response) do
    with {:ok, endpoint} <- resolve_endpoint(server),
         {:ok, notifications} <- Observe.notifications(endpoint, path) do
      Enum.each(notifications, fn notification ->
        Session.notify_observer(notification.connection, notification, response)
      end)

      {:ok, length(notifications)}
    end
  end

  @doc "Like `notify/3` but raises on failure."
  def notify!(server, path, %Response{} = response) do
    case notify(server, path, response) do
      {:ok, count} -> count
      {:error, reason} -> raise ArgumentError, "failed to notify observers: #{inspect(reason)}"
    end
  end

  defp build_endpoint_opts(opts) do
    handler = Keyword.get(opts, :handler)
    router = Keyword.get(opts, :router)
    context = Keyword.get(opts, :context, %{})

    cond do
      handler -> {:ok, endpoint_opts(opts, handler)}
      router -> {:ok, endpoint_opts(opts, {:router, router, context})}
      true -> {:error, {:missing_option, :handler}}
    end
  end

  defp endpoint_opts(opts, handler) do
    opts
    |> Keyword.put(:handler, handler)
    |> Keyword.delete(:router)
    |> Keyword.delete(:context)
  end

  defp resolve_endpoint(server) when is_pid(server) do
    {:ok, server}
  end

  defp resolve_endpoint(server) do
    case GenServer.whereis(server) do
      nil -> {:error, {:endpoint_unavailable, server}}
      endpoint -> {:ok, endpoint}
    end
  end
end
