defmodule Macrina.Message.Opts.Binary do
  @moduledoc """
  This module provides functions for decoding and encoding binary options in the Macrina.Message.Opts module.

  ## Decoder Functions
  - `decode/3`: Decodes a binary message into a list of options and a payload.
  - `decode_block/1`: Decodes a binary block option into a `Macrina.Message.Opts.Block` struct.
  - `decode_length/2`: Decodes the length of an option from a binary.
  - `decode_number/3`: Decodes the number of an option from a binary.
  - `decode_value/3`: Decodes the value of an option from a binary.

  ## Encoder Functions
  - `encode/1`: Encodes a list of options into a binary message.
  - `encode_block/3`: Encodes a block option into a binary.
  - `encode_value/1`: Encodes the value of an option into a binary.
  - `encode_ext/1`: Encodes an extended value for delta or length into a binary.

  ## Types
  - `option`: A tuple representing an option with a name and value.
  - `payload`: A binary representing the payload of a message.
  """

  alias Macrina.Message.{Opts, Opts.Block}

  @type option_value :: binary() | integer() | Block.t()
  @type option :: {name :: binary() | nil, value :: option_value()}
  @type payload :: binary()
  @type decode_error ::
          :invalid_option_delta
          | :invalid_option_length
          | :invalid_payload_marker
          | :truncated_option_delta
          | :truncated_option_length
          | :truncated_option_value
  @type encode_error ::
          :invalid_options
          | {:invalid_option, term()}
          | {:invalid_option_value, binary(), term()}
          | {:unknown_option, binary()}

  # these option types are UINTs
  @unsigned [6, 7, 12, 14, 17, 28, 60]
  # block options are their own type
  @block [23, 27]

  # ------------------------------------------- Decoder ------------------------------------------ #

  @spec decode(message :: binary(), delta_sum :: integer(), [option()]) ::
          {:ok, {[option()], payload()}} | {:error, decode_error()}
  def decode(binary, sum \\ 0, options \\ [])

  def decode(<<>>, _delta_sum, options) do
    reversed_options = Enum.reverse(options)
    {:ok, {reversed_options, <<>>}}
  end

  def decode(<<255>>, _delta_sum, _options) do
    {:error, :invalid_payload_marker}
  end

  def decode(<<255, payload::binary>>, _delta_sum, options) do
    reversed_options = Enum.reverse(options)
    {:ok, {reversed_options, payload}}
  end

  def decode(<<15::4, _length::4, _rest::binary>>, _sum, _options) do
    {:error, :invalid_option_delta}
  end

  def decode(<<_delta::4, 15::4, _rest::binary>>, _sum, _options) do
    {:error, :invalid_option_length}
  end

  def decode(<<delta::4, len::4, rest::binary>>, sum, options) do
    with {:ok, {option_number, rest}} <- decode_number(delta, sum, rest),
         {:ok, {option_length, rest}} <- decode_length(len, rest),
         {:ok, {option, rest}} <- decode_value(option_number, option_length, rest) do
      next_options = next_options(options, option_number, option)

      decode(rest, option_number, next_options)
    end
  end

  @spec decode_block(binary()) :: Block.t()
  def decode_block(<<num::4, m::1, szx::3>>) do
    decode_block(num, m, szx)
  end

  def decode_block(<<num::12, m::1, szx::3>>) do
    decode_block(num, m, szx)
  end

  def decode_block(<<num::28, m::1, szx::3>>) do
    decode_block(num, m, szx)
  end

  @spec decode_block(integer(), integer(), integer()) :: Block.t()
  def decode_block(num, m, szx) do
    %Block{number: num, more: m == 1, size: :math.pow(2, szx + 4) |> Float.ceil() |> trunc()}
  end

  @spec decode_length(integer(), binary()) ::
          {:ok, {integer(), binary()}} | {:error, decode_error()}
  def decode_length(len, bin) when len < 13 do
    {:ok, {len, bin}}
  end

  def decode_length(13, <<len, rest::binary>>) do
    {:ok, {len + 13, rest}}
  end

  def decode_length(13, _bin) do
    {:error, :truncated_option_length}
  end

  def decode_length(14, <<len::16, rest::binary>>) do
    {:ok, {len + 269, rest}}
  end

  def decode_length(14, _bin) do
    {:error, :truncated_option_length}
  end

  @spec decode_number(integer(), integer(), binary()) ::
          {:ok, {integer(), binary()}} | {:error, decode_error()}
  def decode_number(delta, sum, bin) when delta < 13 do
    {:ok, {sum + delta, bin}}
  end

  def decode_number(13, sum, <<delta, rest::binary>>) do
    {:ok, {sum + delta + 13, rest}}
  end

  def decode_number(13, _sum, _bin) do
    {:error, :truncated_option_delta}
  end

  def decode_number(14, sum, <<delta::size(16), rest::binary>>) do
    {:ok, {sum + delta + 269, rest}}
  end

  def decode_number(14, _sum, _bin) do
    {:error, :truncated_option_delta}
  end

  @spec decode_value(integer(), integer(), binary()) ::
          {:ok, {option_value(), binary()}} | {:error, decode_error()}
  def decode_value(_option_number, option_length, bin) when byte_size(bin) < option_length do
    {:error, :truncated_option_value}
  end

  def decode_value(option_number, option_length, bin) do
    <<value::binary-size(option_length), rest::binary>> = bin

    decoded_value = decode_option_value(option_number, value)

    {:ok, {decoded_value, rest}}
  end

  # ------------------------------------------- Encoder ------------------------------------------ #

  @spec encode([option()]) :: {:ok, binary()} | {:error, encode_error()}
  def encode(options) when is_list(options) do
    with {:ok, encoded_options} <- encode_values(options),
         {:ok, options_bin} <- encode_options(encoded_options) do
      {:ok, options_bin}
    end
  end

  def encode(_options) do
    {:error, :invalid_options}
  end

  def encode({number, value}, {sum, existing}) do
    initial_delta = number - sum
    initial_length = byte_size(value)
    {delta, ext_delta} = encode_ext(initial_delta)
    {length, extended_length} = encode_ext(initial_length)

    {number,
     <<
       existing::binary,
       delta::size(4),
       length::size(4),
       ext_delta::binary,
       extended_length::binary,
       value::binary
     >>}
  end

  def encode_block(num, more?, size) do
    m =
      if more? do
        1
      else
        0
      end

    szx = (size |> :math.log2() |> Float.ceil() |> trunc()) - 4

    cond do
      num < 16 -> <<num::4, m::1, szx::3>>
      num < 4096 -> <<num::12, m::1, szx::3>>
      true -> <<num::28, m::1, szx::3>>
    end
  end

  def encode_value({name, value}) when is_binary(name) do
    with {:ok, number} <- encode_option_number(name),
         {:ok, encoded_value} <- encode_option_value(number, name, value) do
      {:ok, {number, encoded_value}}
    end
  end

  def encode_value(option) do
    {:error, {:invalid_option, option}}
  end

  def encode_ext(val) when val >= 269 do
    {14, <<val - 269::size(16)>>}
  end

  def encode_ext(val) when val >= 13 do
    {13, <<val - 13>>}
  end

  def encode_ext(val) do
    {val, <<>>}
  end

  defp next_options(options, _option_number, <<0>>) do
    options
  end

  defp next_options(options, option_number, option) do
    option_name = Opts.name(option_number)
    [{option_name, option} | options]
  end

  defp decode_option_value(option_number, value) do
    cond do
      option_number in @unsigned -> :binary.decode_unsigned(value)
      option_number in @block -> decode_block(value)
      true -> value
    end
  end

  defp encode_values(options) do
    indexed_options = Enum.with_index(options)
    initial_result = {:ok, []}

    case Enum.reduce_while(indexed_options, initial_result, &reduce_encoded_option/2) do
      {:ok, encoded_options} ->
        sorted_options = Enum.sort_by(encoded_options, &sort_encoded_option/1, :asc)
        ordered_options = Enum.map(sorted_options, &elem(&1, 0))

        {:ok, ordered_options}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reduce_encoded_option({option, index}, {:ok, encoded_options}) do
    case encode_value(option) do
      {:ok, encoded_option} ->
        next_option = {encoded_option, index}
        next_options = [next_option | encoded_options]

        {:cont, {:ok, next_options}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp encode_options(encoded_options) do
    initial_result = {:ok, {0, <<>>}}

    case Enum.reduce_while(encoded_options, initial_result, &reduce_encoded_binary/2) do
      {:ok, {_last_number, options_bin}} -> {:ok, options_bin}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reduce_encoded_binary(option, {:ok, encoded}) do
    next_encoded = encode(option, encoded)
    {:cont, {:ok, next_encoded}}
  end

  defp encode_option_number(name) do
    case Opts.number(name) do
      nil -> {:error, {:unknown_option, name}}
      number -> {:ok, number}
    end
  end

  defp encode_option_value(number, name, value) when number in @unsigned do
    if is_integer(value) and value >= 0 do
      encoded_value = :binary.encode_unsigned(value)
      {:ok, encoded_value}
    else
      {:error, {:invalid_option_value, name, value}}
    end
  end

  defp encode_option_value(number, name, value) when number in @block do
    encode_block_value(name, value)
  end

  defp encode_option_value(_number, name, value) do
    if is_binary(value) do
      {:ok, value}
    else
      {:error, {:invalid_option_value, name, value}}
    end
  end

  defp encode_block_value(name, %Block{number: number, more: more, size: size}) do
    valid_block =
      is_integer(number) and number >= 0 and more in [true, false] and valid_block_size?(size)

    if valid_block do
      encoded_block = encode_block(number, more, size)
      {:ok, encoded_block}
    else
      {:error, {:invalid_option_value, name, %Block{number: number, more: more, size: size}}}
    end
  end

  defp encode_block_value(name, value) do
    {:error, {:invalid_option_value, name, value}}
  end

  defp valid_block_size?(size) when is_integer(size) do
    size in [16, 32, 64, 128, 256, 512, 1024]
  end

  defp valid_block_size?(_size) do
    false
  end

  defp sort_encoded_option({{number, _value}, index}) do
    {number, index}
  end
end
