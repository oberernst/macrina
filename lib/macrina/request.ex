defmodule Macrina.Request do
  alias Macrina.Opts.Binary
  alias Macrina.Codes

  defstruct [:code, :message_id, :options, :payload, :token, :type]

  @type t :: %__MODULE__{
          code: atom(),
          message_id: integer(),
          options: [{String.t(), String.t()}],
          payload: String.t(),
          token: String.t(),
          type: :acknowledgement | :confirmable | :non_confirmable | :reset
        }

  @doc """
  Decode binary coap message

  Examples:

      iex> message = <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>
      iex> Macrina.Request.decode(message)
      {:ok, %Macrina.Request{
        code: :put,
        message_id: 12796,
        options: [{"Uri-Path", "resource"}, {"Uri-Query", "who=world"}],
        payload: "payload",
        token: <<123, 92, 211, 222>>,
        type: :confirmable
      }}

      iex> message = <<68, 1, 0, 1, 163, 249, 107, 129, 57, 108, 111, 99, 97, 108, 104, 111, 115,
      iex>              116, 131, 97, 112, 105, 0, 17, 0, 57, 119, 104, 111, 61, 119, 111, 114, 108,
      iex>              100, 255, 100, 97, 116, 97>>
      iex> Macrina.Request.decode(message)
      {:ok, %Macrina.Request{
        code: :get,
        message_id: 1,
        options: [{"Uri-Host", "localhost"}, {"Uri-Path", "api"}, {"Uri-Path", ""}, {"Uri-Query", "who=world"}],
        payload: "data",
        token: <<163, 249, 107, 129>>,
        type: :confirmable
      }}

  """
  @spec decode(binary()) :: {:ok, %__MODULE__{}} | {:error, :bad_version}
  def decode(<<
        # CoAP header
        version::size(2),
        type::size(2),
        token_length::size(4),
        code_class::size(3),
        code_detail::size(5),
        message_id::size(16),

        # CoAP token, options, and data
        rest::binary
      >>)
      when version == 1 do
    {token, rest} = extract_token(rest, token_length)
    {options, payload} = Binary.parse(rest)

    {:ok,
     %__MODULE__{
       code: Codes.parse(code_class, code_detail),
       message_id: message_id,
       options: options,
       payload: payload,
       token: token,
       type: parse_type(type)
     }}
  end

  def decode(_request) do
    {:error, :bad_version}
  end

  def extract_token(bin, len) do
    <<token::binary-size(len), rest::binary>> = bin
    {token, rest}
  end

  def parse_type(0), do: :confirmable
  def parse_type(1), do: :non_confirmable
  def parse_type(2), do: :acknowledgement
  def parse_type(3), do: :reset
end
