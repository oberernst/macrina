defmodule Macrina.Server do
  @moduledoc """
  Public entry point for starting a CoAP server.

  Wraps `Macrina.Endpoint` with ergonomic options for router selection,
  Block1 upload policy, and observer notifications.

  ## Starting a server

      defmodule MyApp.Router do
        @behaviour Macrina.Router

        @impl true
        def call(_request, _context) do
          Macrina.Response.new(:content, payload: "hello", content_format: :text_plain)
        end
      end

      {:ok, _server} = Macrina.Server.start_link(router: MyApp.Router, port: 5683)

  Or with a Block1 policy for streaming uploads:

      block1 = Macrina.Block1.new!(mode: :streaming, preferred_block_size: 512)

      {:ok, _server} = Macrina.Server.start_link(
        router: MyApp.Router,
        port: 5683,
        block1: block1
      )

  ## Options

    * `:router` — a module implementing `Macrina.Router` (required)
    * `:context` — an arbitrary map passed to router callbacks (default: `%{}`)
    * `:port` — UDP port to bind (required)
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
    case Keyword.get(opts, :router) do
      nil -> {:error, {:missing_option, :router}}
      router when is_atom(router) -> {:ok, opts}
    end
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
