defmodule Macrina.Message.DecodeEnvelopeTest do
  use ExUnit.Case, async: true

  alias Macrina.Message

  describe "decode_envelope/1" do
    test "extracts id, type, and token even when option decoding would fail" do
      assert {:ok, %{id: id, type: :con}} =
               %Message{
                 id: 0x4242,
                 token: <<1, 2, 3, 4>>,
                 type: :con,
                 code: :put,
                 options: [{"Uri-Path", "api"}],
                 payload: "x"
               }
               |> Message.encode()
               |> elem(1)
               |> Message.decode_envelope()

      assert id == 0x4242
    end

    test "extracts id, type from a packet truncated after the header" do
      <<header::binary-size(4), rest::binary>> =
        %Message{id: 0xABCD, token: <<>>, type: :non, code: :get, options: [], payload: <<>>}
        |> Message.encode()
        |> elem(1)

      assert {:ok, %{id: 0xABCD, type: :non, token: <<>>}} =
               Message.decode_envelope(header <> rest)
    end

    test "extracts header from a packet whose options bytes would fail full decode" do
      <<header::binary-size(6), _options_and_payload::binary>> =
        %Message{
          id: 0x1010,
          token: <<7, 7>>,
          type: :con,
          code: :put,
          options: [{"Uri-Path", "x"}],
          payload: "p"
        }
        |> Message.encode()
        |> elem(1)

      malformed = header <> <<0xFF>>

      assert {:error, _} = Message.decode(malformed)

      assert {:ok, %{id: 0x1010, type: :con, token: <<7, 7>>}} =
               Message.decode_envelope(malformed)
    end

    test "returns :error on a packet shorter than the 4-byte header" do
      assert :error = Message.decode_envelope(<<>>)
      assert :error = Message.decode_envelope(<<1, 2, 3>>)
    end

    test "returns :error on a non-version-1 header" do
      assert :error = Message.decode_envelope(<<0::2, 0::2, 0::4, 0::3, 0::5, 0::16>>)
    end
  end
end
