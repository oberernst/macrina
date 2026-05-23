defmodule Macrina.Message.CodecPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  @moduletag :property

  defp method_code do
    StreamData.member_of([:get, :post, :put, :delete])
  end

  defp message_type do
    StreamData.member_of([:con, :non])
  end

  defp token do
    StreamData.binary(min_length: 0, max_length: 8)
  end

  defp message_id do
    StreamData.integer(0..0xFFFF)
  end

  defp payload do
    StreamData.binary(min_length: 0, max_length: 1024)
  end

  defp uri_path_segment do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 16)
  end

  defp uri_path_options do
    StreamData.list_of(uri_path_segment(), min_length: 0, max_length: 4)
    |> StreamData.map(fn segments ->
      Enum.map(segments, fn segment -> {"Uri-Path", segment} end)
    end)
  end

  defp content_format_option do
    StreamData.one_of([
      StreamData.constant([]),
      StreamData.constant([{"Content-Format", 0}]),
      StreamData.constant([{"Content-Format", 40}]),
      StreamData.constant([{"Content-Format", 50}])
    ])
  end

  defp request_tag_option do
    StreamData.one_of([
      StreamData.constant([]),
      StreamData.binary(min_length: 1, max_length: 8)
      |> StreamData.map(fn tag -> [{"Request-Tag", tag}] end)
    ])
  end

  defp block1_option do
    StreamData.one_of([
      StreamData.constant([]),
      StreamData.tuple({
        StreamData.integer(0..0xFFFF),
        StreamData.boolean(),
        StreamData.member_of([16, 32, 64, 128, 256, 512, 1024])
      })
      |> StreamData.map(fn {n, m, s} -> [{"Block1", %Block{number: n, more: m, size: s}}] end)
    ])
  end

  defp options do
    StreamData.bind(uri_path_options(), fn paths ->
      StreamData.bind(content_format_option(), fn cf ->
        StreamData.bind(request_tag_option(), fn rt ->
          StreamData.map(block1_option(), fn b1 ->
            paths ++ cf ++ rt ++ b1
          end)
        end)
      end)
    end)
  end

  property "encode → decode preserves request semantics" do
    check all(
            code <- method_code(),
            type <- message_type(),
            id <- message_id(),
            token <- token(),
            opts <- options(),
            payload <- payload(),
            max_runs: 200
          ) do
      msg =
        Message.build!(code,
          id: id,
          token: token,
          type: type,
          options: opts,
          payload: payload
        )

      assert {:ok, bin} = Message.encode(msg)
      assert {:ok, decoded} = Message.decode(bin)

      assert decoded.code == msg.code
      assert decoded.id == msg.id
      assert decoded.token == msg.token
      assert decoded.type == msg.type
      assert decoded.payload == msg.payload

      # Option order isn't preserved across encode/decode for repeated
      # numbers handled by `next_options`; canonicalize via name + value.
      assert Enum.sort(decoded.options) == Enum.sort(msg.options)
    end
  end

  property "encode → decode → encode is a fixed point" do
    check all(
            code <- method_code(),
            type <- message_type(),
            id <- message_id(),
            token <- token(),
            opts <- options(),
            payload <- payload(),
            max_runs: 100
          ) do
      msg =
        Message.build!(code,
          id: id,
          token: token,
          type: type,
          options: opts,
          payload: payload
        )

      assert {:ok, bin1} = Message.encode(msg)
      assert {:ok, decoded} = Message.decode(bin1)
      assert {:ok, bin2} = Message.encode(decoded)

      assert bin1 == bin2
    end
  end
end
