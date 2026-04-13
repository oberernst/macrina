defmodule Macrina.RequestTest do
  use ExUnit.Case, async: true

  alias Macrina.{Message, Request, Response, Telemetry}

  test "from_uri parses a coap uri into request fields and options" do
    request = Request.from_uri(:get, "coap://Example.com:5684/sensors/temp?unit=c")

    assert request.scheme == :coap
    assert request.host == "example.com"
    assert request.port == 5684
    assert request.path == ["sensors", "temp"]
    assert request.query == ["unit=c"]

    message = Request.to_message(request)

    assert {"Uri-Host", "example.com"} in message.options
    assert {"Uri-Port", 5684} in message.options
    assert {"Uri-Path", "sensors"} in message.options
    assert {"Uri-Path", "temp"} in message.options
    assert {"Uri-Query", "unit=c"} in message.options
  end

  test "relative uris omit host and port options" do
    request = Request.from_uri(:get, "/status?verbose=true")
    message = Request.to_message(request)

    refute Enum.any?(message.options, fn {name, _value} -> name == "Uri-Host" end)
    refute Enum.any?(message.options, fn {name, _value} -> name == "Uri-Port" end)
    assert {"Uri-Path", "status"} in message.options
    assert {"Uri-Query", "verbose=true"} in message.options
  end

  test "response converts from messages" do
    message = Message.build(:content, payload: "ok", options: [{"Content-Format", 0}], type: :ack)
    response = Response.from_message(message)

    assert response.code == :content
    assert response.payload == "ok"
    assert response.type == :ack
    assert {"Content-Format", 0} in response.options
  end

  test "telemetry event names are prefixed" do
    assert Telemetry.event_name([:client, :request]) == [:macrina, :client, :request]
  end
end
