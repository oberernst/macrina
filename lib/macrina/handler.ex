defmodule Macrina.Handler do
  alias Macrina.{Connection, Message, Request, Response, Telemetry}

  @type t :: module() | {:router, module(), map()}

  @callback call(Connection.t(), Message.t() | binary()) :: Message.t() | nil

  def call(handler, %Connection{} = connection, %Message{} = message) do
    case handler do
      {:router, router, context} -> call_router(router, context, connection, message)
      module when is_atom(module) -> module.call(connection, message)
    end
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

  defp router_error_response(router, message, reason) do
    Telemetry.execute(
      [:server, :router, :error],
      %{count: 1},
      %{error: reason, router: router}
    )

    Message.response(message, code: :internal_server_error, type: :ack)
  end
end
