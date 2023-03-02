defmodule Macrina.Message.Opts.Binary do
  alias Macrina.Message.{Opts, Opts.Block}

  @type option :: {name :: binary(), value :: binary()}
  @type payload :: binary()

  # these option types are UINTs
  @unsigned [7, 12, 14, 17, 60]
  # block options are their own type
  @block [23, 27]

  # ------------------------------------------- Decoder ------------------------------------------ #

  @spec decode(message :: binary(), delta_sum :: integer(), [option()]) :: {[option], payload()}
  def decode(binary, sum \\ 0, options \\ [])

  def decode(<<>>, _delta_sum, options) do
    {options, <<>>}
  end

  def decode(<<255, payload::binary>>, _delta_sum, options) do
    {options, payload}
  end

  def decode(<<delta::4, len::4, rest::binary>>, sum, options) do
    {option_number, rest} = decode_number(delta, sum, rest)
    {option_length, rest} = decode_length(len, rest)
    {option, rest} = decode_value(option_number, option_length, rest)

    case option do
      <<0>> -> decode(rest, option_number, options)
      _ -> decode(rest, option_number, options ++ [{Opts.name(option_number), option}])
    end
  end

  def decode_block(<<num::4, m::1, szx::3>>), do: decode_block(num, m, szx)
  def decode_block(<<num::12, m::1, szx::3>>), do: decode_block(num, m, szx)
  def decode_block(<<num::28, m::1, szx::3>>), do: decode_block(num, m, szx)

  def decode_block(num, m, szx) do
    %Block{number: num, more: m == 1, size: :math.pow(2, szx + 4) |> trunc()}
  end

  @spec decode_length(integer(), binary()) :: {integer(), binary()}
  def decode_length(len, bin) when len < 13 do
    {len, bin}
  end

  def decode_length(13, bin) do
    <<len, rest::binary>> = bin
    {len + 13, rest}
  end

  def decode_length(14, bin) do
    <<len::16, rest::binary>> = bin
    {len + 269, rest}
  end

  @spec decode_number(integer(), integer(), binary()) :: {integer(), binary()}
  def decode_number(delta, sum, bin) when delta < 13 do
    {sum + delta, bin}
  end

  def decode_number(13, sum, bin) do
    <<delta, rest::binary>> = bin
    {sum + delta + 13, rest}
  end

  def decode_number(14, sum, bin) do
    <<delta::size(16), rest::binary>> = bin
    {sum + delta + 269, rest}
  end

  def decode_value(option_number, option_length, bin) do
    <<value::binary-size(option_length), rest::binary>> = bin

    cond do
      option_number in @unsigned -> {:binary.decode_unsigned(value), rest}
      option_number in @block -> {nil, rest}
      true -> {value, rest}
    end
  end

  # ------------------------------------------- Encoder ------------------------------------------ #

  def encode(options) when is_list(options) do
    options
    |> Enum.map(&encode_value/1)
    |> Enum.sort_by(&elem(&1, 0), :asc)
    |> Enum.reduce({0, <<>>}, &encode/2)
    |> elem(1)
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
    m = if more?, do: 1, else: 0
    szx = trunc(:math.log2(size) - 4)

    cond do
      num < 16 -> <<num::4, m::1, szx::3>>
      num < 4096 -> <<num::12, m::1, szx::3>>
      true -> <<num::28, m::1, szx::3>>
    end
  end

  def encode_value({name, value}) do
    number = Opts.number(name)

    cond do
      number in @unsigned -> {number, :binary.encode_unsigned(value)}
      number in @block -> {:number, encode_block(value.number, value.more, byte_size(value.bin))}
      true -> {number, value}
    end
  end

  def encode_ext(val) when val >= 269, do: {14, <<val - 269::size(16)>>}
  def encode_ext(val) when val >= 13, do: {13, <<val - 13>>}
  def encode_ext(val), do: {val, <<>>}
end
