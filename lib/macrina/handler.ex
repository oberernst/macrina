defmodule Macrina.Handler do
  alias Macrina.{Block1.Chunk, Connection, Message, Request, Response, Telemetry}

  @type t :: module() | {:router, module(), map()}

  @callback call(Connection.t(), Message.t() | Chunk.t() | binary()) :: Message.t() | nil

  def call(handler, %Connection{} = connection, %Message{} = message) do
    case handler do
      {:router, router, context} -> call_router(router, context, connection, message)
      module when is_atom(module) -> module.call(connection, message)
    end
  end

  def call({:router, router, context}, %Connection{} = connection, %Chunk{} = chunk) do
    call_router_block1(router, context, connection, chunk)
  end

  def call(module, %Connection{} = connection, %Chunk{} = chunk) when is_atom(module) do
    module.call(connection, chunk)
  end

  defp call_router(router, context, connection, message) do
    peer = %{ip: connection.ip, port: connection.port}
    router_context = Map.merge(context, %{connection: connection, peer: peer})

    with {:ok, request} <- Request.from_message(message),
         %Response{} = response <- router.call(request, router_context),
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
