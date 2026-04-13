defmodule Macrina.MessageTest do
  use ExUnit.Case, async: true

  alias Macrina.{Message, Message.Opts.Block}

  test "build uses provided options directly" do
    options = [{"Uri-Path", "temperature"}, {"Uri-Query", "unit=c"}]
    message = Message.build(:get, options: options, payload: "", type: :con)

    assert message.options == options
    assert message.code == :get
    assert message.type == :con
  end

  test "response preserves request id and token" do
    request = Message.build(:get, id: 11, token: <<1, 2, 3, 4>>, type: :con)
    response = Message.response(request, code: :content, payload: "ok", type: :ack)

    assert response.id == 11
    assert response.token == <<1, 2, 3, 4>>
    assert response.code == :content
    assert response.payload == "ok"
  end

  test "response slices blockwise payloads" do
    control_block = %Block{number: 1, more: false, size: 4}
    request = Message.build(:get, id: 22, token: <<9, 9, 9, 9>>, control_block: control_block)

    response = Message.response(request, code: :content, payload: "abcdefgh", type: :ack)

    assert response.payload == "efgh"
    assert {"Block2", %Block{number: 1, more: false, size: 4}} in response.options
  end

  test "decode rejects token lengths above eight bytes" do
    packet = <<1::2, 0::2, 9::4, 0::3, 1::5, 1::16, 0::size(72)>>

    assert Message.decode(packet) == {:error, :invalid_token_length}
  end

  test "decode rejects an empty payload marker" do
    packet = <<1::2, 0::2, 0::4, 0::3, 1::5, 1::16, 255>>

    assert Message.decode(packet) == {:error, :invalid_payload_marker}
  end

  test "decode rejects empty messages with a token" do
    packet = <<1::2, 2::2, 1::4, 0::3, 0::5, 1::16, 7>>

    assert Message.decode(packet) == {:error, :invalid_empty_message}
  end

  test "encode normalizes empty messages to legal empty acks" do
    message = Message.build(:empty, id: 77, payload: "ignored", token: <<1, 2, 3>>, type: :non)

    assert {:ok, encoded_message} = Message.encode(message)
    assert encoded_message == <<1::2, 2::2, 0::4, 0::3, 0::5, 77::16>>
  end

  test "encode omits the payload marker for empty payloads" do
    message = Message.build(:get, id: 88, payload: <<>>, token: <<1, 2, 3, 4>>, type: :con)
    assert {:ok, packet} = Message.encode(message)

    assert Message.decode(packet) == {:ok, message}
  end

  test "encode preserves option order for repeated option numbers" do
    options = [{"Uri-Path", "api"}, {"Uri-Path", "v1"}, {"Uri-Path", "status"}]
    message = Message.build(:get, id: 89, options: options, token: <<1, 2, 3, 4>>, type: :con)

    assert {:ok, packet} = Message.encode(message)
    assert {:ok, decoded_message} = Message.decode(packet)
    assert decoded_message.options == options
  end

  test "encode rejects token lengths above eight bytes" do
    message = Message.build(:get, id: 99, token: <<1, 2, 3, 4, 5, 6, 7, 8, 9>>, type: :con)

    assert Message.encode(message) == {:error, :invalid_token_length}
  end

  test "encode rejects unknown options" do
    message = Message.build(:get, id: 100, options: [{"Unknown-Option", "value"}], type: :con)

    assert Message.encode(message) ==
             {:error, {:invalid_options, {:unknown_option, "Unknown-Option"}}}
  end

  test "encode rejects invalid option values" do
    message =
      Message.build(:get, id: 101, options: [{"Content-Format", "text/plain"}], type: :con)

    assert Message.encode(message) ==
             {:error, {:invalid_options, {:invalid_option_value, "Content-Format", "text/plain"}}}
  end

  test "encode rejects invalid types" do
    message = %Message{Message.build(:get, id: 102, type: :con) | type: :invalid}

    assert Message.encode(message) == {:error, :invalid_type}
  end

  test "encode rejects invalid payloads" do
    message = %Message{Message.build(:get, id: 103, type: :con) | payload: %{value: 1}}

    assert Message.encode(message) == {:error, :invalid_payload}
  end

  test "decode rejects unknown response codes" do
    packet = <<1::2, 0::2, 0::4, 7::3, 31::5, 1::16>>

    assert Message.decode(packet) == {:error, :unknown_code}
  end

  test "decode rejects reserved option delta values" do
    packet = <<1::2, 0::2, 0::4, 0::3, 1::5, 1::16, 240>>

    assert Message.decode(packet) == {:error, :invalid_option_delta}
  end

  test "decode rejects truncated option values" do
    packet = <<1::2, 0::2, 0::4, 0::3, 1::5, 1::16, 177>>

    assert Message.decode(packet) == {:error, :truncated_option_value}
  end
end
