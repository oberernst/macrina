defmodule Macrina.Handler do
  @moduledoc false

  # Internal router dispatch. The session holds a `{router_module, context}`
  # tuple and calls `Macrina.Handler.call/3` to route each decoded message or
  # Block1 chunk through the user's `Macrina.Router` implementation. Discovery
  # responses (`/.well-known/core`) and router error replies are produced
  # here too so `Macrina.Peer.Session` doesn't need to know about routing.

  alias Macrina.{
    Block1.Chunk,
    Discovery,
    Message,
    Peer.State,
    Request,
    Response,
    Router,
    Telemetry
  }

  @type target :: {router :: module(), context :: map()}

  @spec call(target(), State.t(), Message.t() | Chunk.t()) :: Message.t() | nil
  def call({router, context}, %State{} = connection, %Message{} = message)
      when is_atom(router) and is_map(context) do
    call_router(router, context, connection, message)
  end

  def call({router, context}, %State{} = connection, %Chunk{} = chunk)
      when is_atom(router) and is_map(context) do
    call_router_block1(router, context, connection, chunk)
  end

  defp call_router(router, context, connection, message) do
    peer = %{ip: connection.ip, port: connection.port}
    router_context = Map.merge(context, %{connection: connection, peer: peer})

    with {:ok, request} <- Request.from_message(message),
         %Response{} = response <- router_response(router, request, router_context),
         {:ok, reply} <- Response.to_message(response, message) do
      reply
    else
      nil -> nil
      {:error, reason} -> router_error_response(router, message, reason)
    end
  end

  defp call_router_block1(router, context, connection, chunk) do
    peer = %{ip: connection.ip, port: connection.port}
    router_context = Map.merge(context, %{connection: connection, peer: peer})

    with %Response{} = response <- router.block1(chunk, router_context),
         {:ok, reply} <- Response.to_message(response, chunk.message) do
      reply
    else
      nil -> nil
      {:error, reason} -> router_error_response(router, chunk.message, reason)
    end
  end

  defp router_response(router, %Request{} = request, router_context) do
    case discovery_response(router, request, router_context) do
      {:ok, %Response{} = response} -> response
      nil -> router.call(request, router_context)
      {:error, reason} -> {:error, reason}
    end
  end

  defp discovery_response(router, %Request{} = request, router_context) do
    if Discovery.discovery_request?(request) and Router.supports_discovery?(router) do
      case router.discover(request, router_context) do
        nil -> nil
        resources -> Discovery.response(resources, request)
      end
    end
  end

  defp router_error_response(router, message, reason) do
    Telemetry.execute(
      [:server, :router, :error],
      %{count: 1},
      %{error: reason, router: router}
    )

    case Message.response(message, code: :internal_server_error, type: :ack) do
      {:ok, reply} -> reply
      {:error, _build_reason} -> nil
    end
  end
end
