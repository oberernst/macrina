defmodule Macrina.HandlerTest do
  use ExUnit.Case, async: true

  alias Macrina.{Connection, Handler, Message, Response}

  defmodule InvalidRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context) do
      %Response{Response.new(:content) | payload: %{bad: true}}
    end
  end

  test "router handler falls back to an internal server error reply when response conversion fails" do
    connection = %Connection{ip: {127, 0, 0, 1}, port: 5683}
    request = Message.build!(:get, id: 12, token: <<1, 2, 3, 4>>, type: :con)

    reply = Handler.call({:router, InvalidRouter, %{}}, connection, request)

    assert %Message{code: :internal_server_error, id: 12, token: <<1, 2, 3, 4>>, type: :ack} =
             reply
  end
end
