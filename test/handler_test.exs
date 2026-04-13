defmodule Macrina.HandlerTest do
  use ExUnit.Case, async: true

  alias Macrina.{Block1.Chunk, Connection, Handler, Message, Message.Opts.Block, Response}

  defmodule ChunkHandler do
    def call(_connection, %Chunk{} = chunk) do
      send(self(), {:chunk, chunk.complete, chunk.bytes, chunk.message.payload})
      nil
    end
  end

  defmodule InvalidRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context) do
      %Response{Response.new(:content) | payload: %{bad: true}}
    end
  end

  defmodule StreamingRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context) do
      Response.new(:changed)
    end

    @impl true
    def block1(%Chunk{} = chunk, _context) do
      send(self(), {:router_chunk, chunk.complete, chunk.bytes, chunk.message.payload})

      if chunk.complete do
        Response.new(:changed)
      end
    end
  end

  test "router handler falls back to an internal server error reply when response conversion fails" do
    connection = %Connection{ip: {127, 0, 0, 1}, port: 5683}
    request = Message.build!(:get, id: 12, token: <<1, 2, 3, 4>>, type: :con)

    reply = Handler.call({:router, InvalidRouter, %{}}, connection, request)

    assert %Message{code: :internal_server_error, id: 12, token: <<1, 2, 3, 4>>, type: :ack} =
             reply
  end

  test "module handlers receive block1 streaming chunks" do
    connection = %Connection{}
    request = Message.build!(:put, id: 1, token: <<1>>, type: :con)

    chunk = %Chunk{
      block: %Block{number: 0, more: true, size: 64},
      bytes: 64,
      complete: false,
      content_format: 0,
      message: %Message{request | payload: "data"}
    }

    assert nil == Handler.call(ChunkHandler, connection, chunk)
    assert_receive {:chunk, false, 64, "data"}
  end

  test "router handlers receive block1 streaming chunks through the router callback" do
    connection = %Connection{ip: {127, 0, 0, 1}, port: 5683}
    request = Message.build!(:put, id: 13, token: <<1, 2, 3, 5>>, type: :con)

    chunk = %Chunk{
      block: %Block{number: 1, more: false, size: 64},
      bytes: 68,
      complete: true,
      content_format: 0,
      message: %Message{request | payload: "tail"}
    }

    reply = Handler.call({:router, StreamingRouter, %{}}, connection, chunk)

    assert_receive {:router_chunk, true, 68, "tail"}
    assert %Message{code: :changed, id: 13, token: <<1, 2, 3, 5>>, type: :ack} = reply
  end
end
