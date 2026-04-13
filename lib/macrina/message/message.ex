defmodule Macrina.Message do
  @moduledoc """
  Low-level CoAP message codec.

  Encodes and decodes CoAP messages to and from their binary wire format
  (RFC 7252, Section 3). Also provides builders for constructing request and
  response messages with automatic token generation and message-ID assignment.

  Application code normally uses `Macrina.Request` and `Macrina.Response`
  instead of this module directly.
  """

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
          type: :ack | :con | :non | :rst
        }
  @type decode_error ::
          :bad_version
          | :invalid_empty_message
          | :invalid_token_length
          | :malformed_message
          | :unknown_code
          | Binary.decode_error()
  @type encode_error ::
          :invalid_code
          | :invalid_id
          | :invalid_payload
          | :invalid_token
          | :invalid_token_length
          | :invalid_type
          | {:invalid_options, Binary.encode_error()}
  @type build_error :: encode_error()
  @type response_error :: build_error()

  @max_block_size 1024
  @method_codes Codes.method_codes()
  @response_codes Codes.response_codes()
  @spec build(atom(), keyword()) :: {:ok, t()} | {:error, build_error()}
  def build(code, opts \\ [])

  def build(code, opts) when is_atom(code) and is_list(opts) do
    options = Keyword.get(opts, :options, [])
    id = id_or_default(Keyword.get(opts, :id))
    payload = payload_or_default(Keyword.get(opts, :payload))
    token = token_or_default(Keyword.get(opts, :token))
    type = type_or_default(Keyword.get(opts, :type))

    with :ok <- validate_code(code),
         :ok <- validate_id(id),
         :ok <- validate_payload(payload),
         :ok <- validate_token(token),
         :ok <- validate_type(type),
         :ok <- validate_options(options) do
      control_block = Keyword.get(opts, :control_block, control_block(code, options))
      descriptive_block = Keyword.get(opts, :descriptive_block, descriptive_block(code, options))

      message = %__MODULE__{
        code: code,
        control_block: control_block,
        descriptive_block: descriptive_block,
        id: id,
        options: options,
        payload: payload,
        token: token,
        type: type
      }

      {:ok, message}
    end
  end

  def build(_code, _opts) do
    {:error, :invalid_code}
  end

  def build!(code, opts \\ []) do
    case build(code, opts) do
      {:ok, message} -> message
      {:error, reason} -> raise ArgumentError, "invalid CoAP message: #{inspect(reason)}"
    end
  end

  def response(msg, opts \\ [])
  @spec response(t(), keyword()) :: {:ok, t()} | {:error, response_error()}

  def response(%__MODULE__{control_block: %Block{size: s}} = m, params)
      when s > @max_block_size do
    type = Keyword.get(params, :type, :non)
    build(:bad_request, id: m.id, token: m.token, type: type)
  end

  def response(%__MODULE__{control_block: %Block{} = b} = msg, params) do
    payload = payload_or_default(Keyword.get(params, :payload))
    options = Keyword.get(params, :options, [])
    code = Keyword.get(params, :code, :content)

    with :ok <- validate_payload(payload) do
      {response_code, response_options, response_payload} =
        response_block_parts(b, code, options, payload)

      response_opts =
        Keyword.merge(params,
          id: msg.id,
          options: response_options,
          payload: response_payload,
          token: msg.token
        )

      build(response_code, response_opts)
    end
  end

  def response(%__MODULE__{id: id, token: token}, opts) do
    code = Keyword.get(opts, :code, :valid)
    opts = opts |> Keyword.put(:id, id) |> Keyword.put(:token, token)
    build(code, opts)
  end

  def response!(%__MODULE__{} = message, opts \\ []) do
    case response(message, opts) do
      {:ok, reply} -> reply
      {:error, reason} -> raise ArgumentError, "invalid CoAP response: #{inspect(reason)}"
    end
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
  @spec decode(binary()) :: {:ok, %__MODULE__{}} | {:error, decode_error()}
  def decode(<<version::2, _rest::bits>>) when version != 1 do
    {:error, :bad_version}
  end

  def decode(<<1::2, _type::2, token_length::4, _rest::binary>>) when token_length > 8 do
    {:error, :invalid_token_length}
  end

  def decode(
        <<1::2, type::2, token_length::4, code_class::3, code_detail::5, id::16,
          token::binary-size(token_length), rest::binary>>
      ) do
    with {:ok, {options, payload}} <- Binary.decode(rest),
         {:ok, code} <- decode_code(code_class, code_detail),
         {:ok, decoded_type} <- decode_type(type),
         {:ok, message} <- decode_message(code, id, options, payload, token, decoded_type) do
      {:ok, message}
    end
  end

  def decode(_request) do
    {:error, :malformed_message}
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
      {:ok, <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>}

      iex> message = %Macrina.Message{
      iex>   id: Enum.random(10000..19999),
      iex>   options: [{"Uri-Path", "api"}, {"Uri-Path", ""}, {"Uri-Path", "oberernst-seekrit-stash"}],
      iex>   payload: "",
      iex>   token: :crypto.strong_rand_bytes(8),
      iex>   type: :non,
      iex>   code: :get
      iex> }
      iex> {:ok, bin} = Macrina.Message.encode(message)
      iex> {:ok, decoded} = Macrina.Message.decode(bin)
      iex> decoded
      message

  """
  @spec encode(t()) :: {:ok, binary()} | {:error, encode_error()}
  def encode(%__MODULE__{code: :empty, id: id, type: type}) do
    with :ok <- validate_id(id),
         {:ok, encoded_type} <- encode_empty_type(type) do
      encoded_message =
        <<1::size(2), encoded_type::size(2), 0::size(4), 0::size(3), 0::size(5), id::size(16)>>

      {:ok, encoded_message}
    end
  end

  def encode(%__MODULE__{
        code: code,
        id: id,
        options: options,
        payload: payload,
        token: token,
        type: type
      }) do
    with :ok <- validate_id(id),
         :ok <- validate_token(token),
         {:ok, encoded_type} <- encode_type(type),
         {:ok, {code_class, code_detail}} <- encode_code(code),
         {:ok, options_bin} <- encode_options(options),
         {:ok, payload_bin} <- encode_payload(payload) do
      encoded_message =
        <<1::size(2), encoded_type::size(2), byte_size(token)::size(4), code_class::size(3),
          code_detail::size(5), id::size(16), token::binary, options_bin::binary,
          payload_bin::binary>>

      {:ok, encoded_message}
    end
  end

  def encode!(%__MODULE__{} = message) do
    case encode(message) do
      {:ok, encoded_message} -> encoded_message
      {:error, reason} -> raise ArgumentError, "invalid CoAP message: #{inspect(reason)}"
    end
  end

  defp decode_message(:empty, id, [], <<>>, <<>>, type) when type in [:ack, :rst] do
    message = %__MODULE__{
      control_block: nil,
      descriptive_block: nil,
      code: :empty,
      id: id,
      options: [],
      payload: <<>>,
      token: <<>>,
      type: type
    }

    {:ok, message}
  end

  defp decode_message(:empty, _id, _options, _payload, _token, _type) do
    {:error, :invalid_empty_message}
  end

  defp decode_message(code, id, options, payload, token, type) do
    control_block = control_block(code, options)
    descriptive_block = descriptive_block(code, options)

    message = %__MODULE__{
      control_block: control_block,
      descriptive_block: descriptive_block,
      code: code,
      id: id,
      options: options,
      payload: payload,
      token: token,
      type: type
    }

    {:ok, message}
  end

  defp decode_code(code_class, code_detail) do
    case Codes.decode(code_class, code_detail) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, :unknown_code}
    end
  end

  defp decode_type(type) do
    decoded_type = Types.parse(type)
    {:ok, decoded_type}
  end

  defp encode_code(code) do
    case Codes.encode(code) do
      {:ok, encoded_code} -> {:ok, encoded_code}
      :error -> {:error, :invalid_code}
    end
  end

  defp id_or_default(nil), do: Enum.random(10000..19999)
  defp id_or_default(id), do: id

  defp payload_or_default(nil), do: <<>>
  defp payload_or_default(payload), do: payload

  defp token_or_default(nil), do: :crypto.strong_rand_bytes(4)
  defp token_or_default(token), do: token

  defp type_or_default(nil), do: :non
  defp type_or_default(type), do: type

  defp encode_empty_type(type) do
    case encode_type(type) do
      {:ok, 3} -> {:ok, 3}
      {:ok, _encoded_type} -> {:ok, 2}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_type(type) do
    case Types.encode(type) do
      {:ok, encoded_type} -> {:ok, encoded_type}
      :error -> {:error, :invalid_type}
    end
  end

  defp encode_options(options) when is_list(options) do
    case Binary.encode(options) do
      {:ok, options_bin} -> {:ok, options_bin}
      {:error, reason} -> {:error, {:invalid_options, reason}}
    end
  end

  defp encode_options(_options) do
    {:error, {:invalid_options, :invalid_options}}
  end

  defp encode_payload(nil), do: {:ok, <<>>}
  defp encode_payload(<<>>), do: {:ok, <<>>}

  defp encode_payload(payload) when is_binary(payload) do
    encoded_payload = <<255, payload::binary>>
    {:ok, encoded_payload}
  end

  defp encode_payload(_payload) do
    {:error, :invalid_payload}
  end

  defp validate_code(code) do
    if Codes.valid_code?(code) do
      :ok
    else
      {:error, :invalid_code}
    end
  end

  defp validate_id(id) when is_integer(id) and id >= 0 and id <= 65_535, do: :ok
  defp validate_id(_id), do: {:error, :invalid_id}

  defp validate_options(options) when is_list(options) do
    case Binary.encode(options) do
      {:ok, _encoded_options} -> :ok
      {:error, reason} -> {:error, {:invalid_options, reason}}
    end
  end

  defp validate_options(_options) do
    {:error, {:invalid_options, :invalid_options}}
  end

  defp validate_payload(payload) do
    case encode_payload(payload) do
      {:ok, _encoded_payload} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_token(token) when not is_binary(token), do: {:error, :invalid_token}
  defp validate_token(token) when byte_size(token) > 8, do: {:error, :invalid_token_length}
  defp validate_token(_token), do: :ok

  defp validate_type(type) do
    if Types.valid_type?(type) do
      :ok
    else
      {:error, :invalid_type}
    end
  end

  defp response_block_parts(block, code, options, payload) do
    payload_size = byte_size(payload)
    offset = block.number * block.size

    cond do
      payload_size < offset ->
        {:bad_request, options, <<>>}

      payload_size > (block.number + 1) * block.size ->
        block_payload = :binary.part(payload, offset, block.size)
        response_block = %Block{number: block.number, more: true, size: block.size}
        response_options = [{"Block2", response_block} | options]

        {code, response_options, block_payload}

      true ->
        block_payload = :binary.part(payload, offset, payload_size - offset)
        response_block = %Block{number: block.number, more: false, size: block.size}
        response_options = [{"Block2", response_block} | options]

        {code, response_options, block_payload}
    end
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
