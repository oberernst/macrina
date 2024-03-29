defmodule Macrina.Message do
  alias Macrina.{Codes, Message.Opts.Binary, Message.Opts.Block, Types}

  defstruct [:code, :control_block, :descriptive_block, :id, :options, :payload, :token, :type]

  @type t :: %__MODULE__{
          code: atom(),
          control_block: Block.t(),
          descriptive_block: Block.t(),
          id: integer(),
          options: [{String.t(), String.t()}],
          payload: nil | String.t() | map(),
          token: String.t(),
          type: :ack | :con | :non | :res
        }

  @max_block_size 1024
  @method_codes Codes.method_codes()
  @response_codes Codes.response_codes()
  @valid_codes @method_codes ++ @response_codes

  def build(code, opts \\ []) when is_atom(code) when code in @valid_codes do
    options = Keyword.get(opts, :options, [])
    control_block_in_opts = control_block(code, options)
    descriptive_block_in_opts = descriptive_block(code, options)

    %__MODULE__{
      code: code,
      control_block: Keyword.get(opts, :control_block, control_block_in_opts),
      descriptive_block: Keyword.get(opts, :descriptive_block, descriptive_block_in_opts),
      id: Keyword.get(opts, :id, Enum.random(10000..19999)),
      options: Keyword.get(opts, :options, []),
      payload: Keyword.get(opts, :payload, <<>>),
      token: Keyword.get(opts, :token, :crypto.strong_rand_bytes(4)),
      type: Keyword.get(opts, :type, :non)
    }
  end

  def response(msg, opts \\ [])

  def response(%__MODULE__{control_block: %Block{size: s}} = m, params)
      when s > @max_block_size do
    type = Keyword.get(params, :type, :non)
    build(:bad_request, id: m.id, token: m.token, type: type)
  end

  def response(%__MODULE__{control_block: %Block{} = b} = msg, params) do
    payload = Keyword.get(params, :payload, <<>>)
    options = Keyword.get(params, :options, [])
    code = Keyword.get(params, :code, :content)

    payload_size = byte_size(payload)
    offset = b.number * b.size

    {code, options, payload} =
      cond do
        payload_size < offset ->
          {:bad_request, options, <<>>}

        payload_size > (b.number + 1) * b.size ->
          part = :binary.part(payload, offset, b.size)
          block = %Block{number: b.number, more: true, size: b.size}
          {code, [{"Block2", block} | options], part}

        true ->
          part = :binary.part(payload, offset, payload_size - offset)
          block = %Block{number: b.number, more: false, size: b.size}
          {code, [{"Block2", block} | options], part}
      end

    new_params =
      Keyword.merge(params, id: msg.id, options: options, payload: payload, token: msg.token)

    build(code, new_params)
  end

  def response(%__MODULE__{id: id, token: token}, opts) do
    code = Keyword.get(opts, :code, :valid)
    opts = opts |> Keyword.put(:id, id) |> Keyword.put(:token, token)
    build(code, opts)
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
        options: [{"Uri-Host", "localhost"}, {"Uri-Path", "api"}, {"Uri-Path", ""}, {"Content-Format", 0}, {"Uri-Query", "who=world"}],
        payload: "data",
        token: <<163, 249, 107, 129>>,
        type: :con
      }}

  """
  @spec decode(binary()) :: {:ok, %__MODULE__{}} | {:error, :bad_version}
  def decode(
        <<version::2, type::2, token_length::4, code_class::3, code_detail::5, id::16,
          token::binary-size(token_length), rest::binary>>
      )
      when version == 1 do
    {options, payload} = Binary.decode(rest)
    code = Codes.parse(code_class, code_detail)

    message = %__MODULE__{
      control_block: control_block(code, options),
      descriptive_block: descriptive_block(code, options),
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
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{code: :empty, id: id, token: token}) do
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

  @spec control_block(atom(), keyword()) :: Block.t() | nil
  defp control_block(code, options) when code in @method_codes do
    get_block_option(options, "Block2")
  end

  defp control_block(code, options) when code in @response_codes do
    get_block_option(options, "Block1")
  end

  @spec descriptive_block(atom(), keyword()) :: Block.t() | nil
  defp descriptive_block(code, options) when code in @method_codes do
    get_block_option(options, "Block1")
  end

  defp descriptive_block(code, options) when code in @response_codes do
    get_block_option(options, "Block2")
  end

  defp get_block_option(options, block_name) do
    case Enum.find(options, fn {n, _} -> n == block_name end) do
      {_, %Block{} = block} -> block
      _ -> nil
    end
  end
end
