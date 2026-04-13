defmodule Macrina.RequestTest do
  use ExUnit.Case, async: true

  alias Macrina.{ContentFormat, Message, Message.Opts.Block, Request, Response, Telemetry}

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

  test "bare relative uris decompose into path segments" do
    assert {:ok, request} = Request.from_uri(:get, "status/subsystem")
    assert {:ok, message} = Request.to_message(request)

    assert request.path == ["status", "subsystem"]
    refute Enum.any?(message.options, fn {name, _value} -> name == "Uri-Host" end)
    refute Enum.any?(message.options, fn {name, _value} -> name == "Uri-Port" end)
    assert {"Uri-Path", "status"} in message.options
    assert {"Uri-Path", "subsystem"} in message.options
  end

  test "default coap and coaps ports are omitted from message options" do
    assert {:ok, coap_request} = Request.from_uri(:get, "coap://example.com:5683/status")
    assert {:ok, coaps_request} = Request.from_uri(:get, "coaps://example.com:5684/status")

    assert {:ok, coap_message} = Request.to_message(coap_request)
    assert {:ok, coaps_message} = Request.to_message(coaps_request)

    refute Enum.any?(coap_message.options, fn {name, _value} -> name == "Uri-Port" end)
    refute Enum.any?(coaps_message.options, fn {name, _value} -> name == "Uri-Port" end)
  end

  test "uris preserve empty segments and decode path and query values" do
    assert {:ok, request} =
             Request.from_uri(
               :get,
               "coap://example.com/sensors//temperature%20c?unit=deg%20c&&empty="
             )

    assert request.path == ["sensors", "", "temperature c"]
    assert request.query == ["unit=deg c", "", "empty="]

    assert {:ok, message} = Request.to_message(request)
    assert {"Uri-Path", ""} in message.options
    assert {"Uri-Path", "temperature c"} in message.options
    assert {"Uri-Query", ""} in message.options
    assert {"Uri-Query", "empty="} in message.options
  end

  test "root and empty uris do not emit uri path options" do
    assert {:ok, root_request} = Request.from_uri(:get, "coap://example.com/")
    assert {:ok, empty_request} = Request.from_uri(:get, "")

    assert {:ok, root_message} = Request.to_message(root_request)
    assert {:ok, empty_message} = Request.to_message(empty_request)

    assert root_request.path == []
    assert empty_request.path == []

    refute Enum.any?(root_message.options, fn {name, _value} -> name == "Uri-Path" end)
    refute Enum.any?(empty_message.options, fn {name, _value} -> name == "Uri-Path" end)
  end

  test "ipv6 uris normalize host and preserve default-port suppression" do
    assert {:ok, request} = Request.from_uri(:get, "coap://[2001:DB8::1]:5683/status")
    assert {:ok, message} = Request.to_message(request)

    assert request.host == "2001:db8::1"
    assert request.port == 5683
    assert {"Uri-Host", "2001:db8::1"} in message.options
    refute Enum.any?(message.options, fn {name, _value} -> name == "Uri-Port" end)
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

  test "request typed option helpers encode accept and content format" do
    request =
      Request.new(:post,
        accept: :application_json,
        content_format: :text_plain,
        payload: "hello"
      )

    assert Request.accept(request) == :application_json
    assert Request.content_format(request) == :text_plain

    assert {:ok, message} = Request.to_message(request)
    assert {"Accept", 50} in message.options
    assert {"Content-Format", 0} in message.options
  end

  test "request typed option helpers decode known values from messages" do
    assert {:ok, message} =
             Message.build(:post,
               id: 11,
               options: [{"Accept", 60}, {"Content-Format", 50}],
               payload: "{}",
               token: <<1, 2, 3, 4>>,
               type: :con
             )

    assert {:ok, request} = Request.from_message(message)

    assert Request.accept(request) == :application_cbor
    assert Request.content_format(request) == :application_json
  end

  test "response typed option helpers encode content format and max age" do
    response =
      Response.new(:content, content_format: :application_json, max_age: 60, payload: "ok")

    assert Response.content_format(response) == :application_json
    assert Response.max_age(response) == 60

    assert {:ok, message} = Response.to_message(response, nil)
    assert {"Content-Format", 50} in message.options
    assert {"Max-Age", 60} in message.options
  end

  test "content format decode preserves unknown integer values" do
    assert ContentFormat.decode(65_000) == {:ok, 65_000}
  end

  test "typed response helpers still fail safely on invalid content format" do
    response = Response.new(:content, content_format: :bogus_format)

    assert {:error,
            {:invalid_response,
             {:invalid_options, {:invalid_option_value, "Content-Format", :bogus_format}}}} =
             Response.to_message(response, nil)
  end

  test "request typed option helpers encode observe and block options" do
    block2 = %Block{number: 3, more: false, size: 64}

    request =
      Request.new(:get,
        observe: 0,
        block2: block2
      )

    assert Request.observe(request) == 0
    assert Request.block2(request) == block2

    assert {:ok, message} = Request.to_message(request)
    assert {"Observe", 0} in message.options
    assert {"Block2", block2} in message.options
  end

  test "request typed option helpers decode observe and block options from messages" do
    block1 = %Block{number: 1, more: true, size: 32}

    assert {:ok, message} =
             Message.build(:post,
               id: 12,
               options: [{"Observe", 22}, {"Block1", block1}],
               payload: "hello",
               token: <<1, 2, 3, 4>>,
               type: :con
             )

    assert {:ok, request} = Request.from_message(message)

    assert Request.observe(request) == 22
    assert Request.block1(request) == block1
  end

  test "response typed option helpers encode observe and block options" do
    block2 = %Block{number: 2, more: true, size: 128}

    response =
      Response.new(:content,
        observe: 99,
        block2: block2,
        payload: "ok"
      )

    assert Response.observe(response) == 99
    assert Response.block2(response) == block2

    assert {:ok, message} = Response.to_message(response, nil)
    assert {"Observe", 99} in message.options
    assert {"Block2", block2} in message.options
  end

  test "response typed option helpers encode location path and query options" do
    response =
      Response.new(:created,
        location_path: ["devices", "alpha"],
        location_query: ["expand=true", "lang=en"]
      )

    assert Response.location_path(response) == ["devices", "alpha"]
    assert Response.location_query(response) == ["expand=true", "lang=en"]

    assert {:ok, message} = Response.to_message(response, nil)

    assert {"Location-Path", "devices"} in message.options
    assert {"Location-Path", "alpha"} in message.options
    assert {"Location-Query", "expand=true"} in message.options
    assert {"Location-Query", "lang=en"} in message.options
  end

  test "response typed option helpers decode observe and block options from messages" do
    block1 = %Block{number: 0, more: false, size: 16}

    assert {:ok, message} =
             Message.build(:continue,
               id: 13,
               options: [{"Observe", 7}, {"Block1", block1}],
               token: <<1, 2, 3, 4>>,
               type: :ack
             )

    response = Response.from_message(message)

    assert Response.observe(response) == 7
    assert Response.block1(response) == block1
  end

  test "response typed option helpers decode location path and query from messages" do
    assert {:ok, message} =
             Message.build(:created,
               id: 14,
               options: [
                 {"Location-Path", "devices"},
                 {"Location-Path", "beta"},
                 {"Location-Query", "expand=true"}
               ],
               token: <<1, 2, 3, 4>>,
               type: :ack
             )

    response = Response.from_message(message)

    assert Response.location_path(response) == ["devices", "beta"]
    assert Response.location_query(response) == ["expand=true"]
  end
end
