defmodule Macrina.MessageTest do
  use ExUnit.Case, async: true

  alias Macrina.Message

  describe "encode/1 payload marker handling (RFC 7252 §3.1)" do
    test "omits the 0xFF marker when payload is empty" do
      msg = %Message{
        id: 1,
        token: <<1, 2, 3, 4>>,
        type: :con,
        code: :get,
        options: [{"Uri-Path", "api"}],
        payload: <<>>
      }

      bin = Message.encode(msg)

      refute String.contains?(bin, <<0xFF>>),
             "encoded binary must not contain payload marker when payload is empty, got: #{inspect(bin, base: :hex)}"
    end

    test "still emits the 0xFF marker followed by payload when payload is non-empty" do
      msg = %Message{
        id: 1,
        token: <<1, 2, 3, 4>>,
        type: :con,
        code: :put,
        options: [],
        payload: "hello"
      }

      bin = Message.encode(msg)

      assert String.contains?(bin, <<0xFF, "hello">>)
    end

    test "round-trips an empty-payload message through encode and decode" do
      msg = %Message{
        id: 12345,
        token: <<1, 2, 3, 4>>,
        type: :non,
        code: :get,
        options: [{"Uri-Path", "api"}],
        payload: <<>>
      }

      assert {:ok, decoded} = msg |> Message.encode() |> Message.decode()
      assert decoded.payload == <<>>
      assert decoded.code == :get
      assert decoded.options == msg.options
    end
  end

  describe "decode/1 malformed payload marker (RFC 7252 §3.1)" do
    test "rejects a message ending in a bare 0xFF marker with no payload" do
      msg = %Message{
        id: 1,
        token: <<1, 2, 3, 4>>,
        type: :con,
        code: :put,
        options: [{"Uri-Path", "api"}],
        payload: "x"
      }

      encoded = Message.encode(msg)
      head_size = byte_size(encoded) - 2
      <<head::binary-size(head_size), 0xFF, _payload::binary>> = encoded

      malformed = head <> <<0xFF>>

      assert {:error, :malformed_payload_marker} = Message.decode(malformed)
    end
  end
end
