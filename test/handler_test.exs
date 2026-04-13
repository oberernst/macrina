defmodule Macrina.HandlerTest do
  use ExUnit.Case, async: true

  alias Macrina.{
    Block1.Chunk,
    Connection,
    Discovery.Resource,
    Handler,
    Message,
    Message.Opts.Block,
    Request,
    Response
  }

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

  defmodule DiscoverableRouter do
    @behaviour Macrina.Router

    @impl true
    def call(request, _context) do
      send(self(), {:router_call, request.path})
      Response.new(:content, payload: "fallback")
    end

    @impl true
    def discover(request, _context) do
      send(self(), {:router_discover, request.path, Request.accept(request)})

      [
        Resource.new!("/status", rt: "health", ct: [0])
      ]
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

  test "router handlers serve discovery through the discover callback" do
    connection = %Connection{ip: {127, 0, 0, 1}, port: 5683}

    request =
      Message.build!(:get,
        id: 14,
        options: [{"Uri-Path", ".well-known"}, {"Uri-Path", "core"}, {"Accept", 40}],
        token: <<1, 2, 3, 6>>,
        type: :con
      )

    reply = Handler.call({:router, DiscoverableRouter, %{}}, connection, request)

    assert_receive {:router_discover, [".well-known", "core"], :application_link_format}
    refute_receive {:router_call, _path}

    assert reply.payload == "</status>;rt=\"health\";ct=\"0\""
    assert {"Content-Format", 40} in reply.options
    assert %Message{code: :content, id: 14, token: <<1, 2, 3, 6>>, type: :ack} = reply
  end
end
