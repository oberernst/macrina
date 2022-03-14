defmodule Macrina.Message do
  alias Macrina.{Codes, Message.Opts.Binary, Types}

  defstruct [:code, :id, :options, :payload, :token, :type]

  @type t :: %__MODULE__{
          code: atom(),
          id: integer(),
          options: [{String.t(), String.t()}],
          payload: String.t(),
          token: String.t(),
          type: :ack | :con | :non | :res
        }

  def build(code, opts \\ []) when is_atom(code) do
    %__MODULE__{
      code: code,
      id: Keyword.get(opts, :id, Enum.random(10000..19999)),
      options: Keyword.get(opts, :options, []),
      payload: Keyword.get(opts, :payload, <<>>),
      token: Keyword.get(opts, :token, :crypto.strong_rand_bytes(8)),
      type: Keyword.get(opts, :type, :non)
    }
  end

  @doc """
  Decode binary coap message

  Examples:

      iex> message = <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>
      iex> Macrina.Message.decode(message)
      {:ok, %Macrina.Message{
        code: :put,
        id: 12796,
        options: [{"Uri-Path", "resource"}, {"Uri-Query", "who=world"}],
        payload: "payload",
        token: <<123, 92, 211, 222>>,
        type: :con
      }}

      iex> message = <<68, 1, 0, 1, 163, 249, 107, 129, 57, 108, 111, 99, 97, 108, 104, 111, 115,
      iex>              116, 131, 97, 112, 105, 0, 17, 0, 57, 119, 104, 111, 61, 119, 111, 114, 108,
      iex>              100, 255, 100, 97, 116, 97>>
      iex> Macrina.Message.decode(message)
      {:ok, %Macrina.Message{
        code: :get,
        id: 1,
        options: [{"Uri-Host", "localhost"}, {"Uri-Path", "api"}, {"Uri-Path", ""}, {"Uri-Query", "who=world"}],
        payload: "data",
        token: <<163, 249, 107, 129>>,
        type: :con
      }}

  """
  @spec decode(binary()) :: {:ok, %__MODULE__{}} | {:error, :bad_version}
  def decode(
        <<version::size(2), type::size(2), token_length::size(4), code_class::size(3),
          code_detail::size(5), id::size(16), rest::binary>>
      )
      when version == 1 do
    {token, rest} = decode_token(rest, token_length)
    {options, payload} = Binary.decode(rest)

    message = %__MODULE__{
      code: Codes.parse(code_class, code_detail),
      id: id,
      options: options,
      payload: payload,
      token: token,
      type: Types.parse(type)
    }

    {:ok, message}
  end

  def decode(_request) do
    {:error, :bad_version}
  end

  def decode_token(bin, len) do
    <<token::binary-size(len), rest::binary>> = bin
    {token, rest}
  end

  @doc """
  Encode binary coap message

  Examples:

      iex> message = %Macrina.Message{
      iex>   id: 12796,
      iex>   options: [{"Uri-Path", "resource"}, {"Uri-Query", "who=world"}],
      iex>   payload: "payload",
      iex>   token: <<123, 92, 211, 222>>,
      iex>   type: :con,
      iex>   code: :put
      iex> }
      iex> Macrina.Message.encode(message)
      <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>

      iex> message = %Macrina.Message{
      iex>   id: Enum.random(10000..19999),
      iex>   options: [{"Uri-Path", "api"}, {"Uri-Path", ""}, {"Uri-Path", "oberernst-seekrit-stash"}],
      iex>   payload: "",
      iex>   token: :crypto.strong_rand_bytes(8),
      iex>   type: :non,
      iex>   code: :get
      iex> }
      iex> bin = Macrina.Message.encode(message)
      iex> {:ok, decoded} = Macrina.Message.decode(bin)
      iex> decoded
      message

  """
  def encode(%__MODULE__{code: :empty, id: id, token: token, type: :ack}) do
    <<1::size(2), 2::size(2), byte_size(token)::size(4), 0::size(3), 0::size(5), id::size(16),
      token::binary, 0::size(0)>>
  end

  def encode(%__MODULE__{
        code: code,
        id: id,
        options: options,
        payload: payload,
        token: token,
        type: type
      }) do
    {c, dd} = Codes.parse(code)

    <<1::size(2), Types.parse(type)::size(2), byte_size(token)::size(4), c::size(3), dd::size(5),
      id::size(16), token::binary, Binary.encode(options)::binary, 255, payload::binary>>
  end
end
