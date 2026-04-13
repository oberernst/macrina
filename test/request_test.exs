defmodule Macrina.RequestTest do
  use ExUnit.Case, async: true

  alias Macrina.{Message, Request, Response, Telemetry}

  test "from_uri parses a coap uri into request fields and options" do
    assert {:ok, request} = Request.from_uri(:get, "coap://Example.com:5684/sensors/temp?unit=c")

    assert request.scheme == :coap
    assert request.host == "example.com"
    assert request.port == 5684
    assert request.path == ["sensors", "temp"]
    assert request.query == ["unit=c"]

    assert {:ok, message} = Request.to_message(request)

    assert {"Uri-Host", "example.com"} in message.options
    assert {"Uri-Port", 5684} in message.options
    assert {"Uri-Path", "sensors"} in message.options
    assert {"Uri-Path", "temp"} in message.options
    assert {"Uri-Query", "unit=c"} in message.options
  end

  test "relative uris omit host and port options" do
    assert {:ok, request} = Request.from_uri(:get, "/status?verbose=true")
    assert {:ok, message} = Request.to_message(request)

    refute Enum.any?(message.options, fn {name, _value} -> name == "Uri-Host" end)
    refute Enum.any?(message.options, fn {name, _value} -> name == "Uri-Port" end)
    assert {"Uri-Path", "status"} in message.options
    assert {"Uri-Query", "verbose=true"} in message.options
  end

  test "response converts from messages" do
    assert {:ok, message} =
             Message.build(:content, payload: "ok", options: [{"Content-Format", 0}], type: :ack)

    response = Response.from_message(message)

    assert response.code == :content
    assert response.payload == "ok"
    assert response.type == :ack
    assert {"Content-Format", 0} in response.options
  end

  test "telemetry event names are prefixed" do
    assert Telemetry.event_name([:client, :request]) == [:macrina, :client, :request]
  end

  test "from_uri returns an error for unsupported schemes and bang variant raises" do
    assert {:error, {:unsupported_scheme, "https"}} =
             Request.from_uri(:get, "https://example.com/temperature")

    assert_raise ArgumentError, fn ->
      Request.from_uri!(:get, "https://example.com/temperature")
    end
  end

  test "from_uri returns an error for fragments" do
    assert {:error, {:invalid_uri, :fragment_not_allowed}} =
             Request.from_uri(:get, "/temperature#latest")
  end

  test "request round-trips through message conversion" do
    assert {:ok, request} = Request.from_uri(:get, "coap://example.com:5684/sensors/temp?unit=c")
    assert {:ok, message} = Request.to_message(request)
    assert {:ok, rebuilt} = Request.from_message(message)

    assert rebuilt.host == "example.com"
    assert rebuilt.port == 5684
    assert rebuilt.path == ["sensors", "temp"]
    assert rebuilt.query == ["unit=c"]
  end

  test "response converts back to a coap message using request correlation data" do
    assert {:ok, request_message} = Message.build(:get, id: 10, token: <<1, 2, 3, 4>>, type: :con)
    response = Response.new(:content, payload: "ok", options: [{"Content-Format", 0}], type: :ack)

    assert {:ok, reply_message} = Response.to_message(response, request_message)

    assert reply_message.code == :content
    assert reply_message.id == 10
    assert reply_message.token == <<1, 2, 3, 4>>
  end

  test "to_message returns an error for unsupported request codes" do
    request = Request.new(:bogus)

    assert {:error, {:invalid_request, {:unsupported_code, :bogus}}} = Request.to_message(request)
  end

  test "to_message returns an error for invalid request fields" do
    request = %Request{Request.new(:get) | type: :invalid}

    assert {:error, {:invalid_request, :invalid_type}} = Request.to_message(request)
  end

  test "response to_message returns an error for unsupported response codes" do
    response = Response.new(:bogus)

    assert {:error, {:invalid_response, {:unsupported_code, :bogus}}} =
             Response.to_message(response, nil)
  end

  test "response to_message returns an error for invalid response fields" do
    response = %Response{Response.new(:content) | payload: %{bad: true}}

    assert {:error, {:invalid_response, :invalid_payload}} = Response.to_message(response, nil)
  end
end
