defmodule Macrina.Opts.Binary do
  alias Macrina.Opts

  @type option :: {name :: binary(), value :: binary()}
  @type payload :: binary()

  @spec parse(message :: binary(), delta_sum :: integer(), [option()]) :: {[option], payload()}
  def parse(binary, sum \\ 0, options \\ [])

  def parse(<<>>, _delta_sum, options) do
    {options, <<>>}
  end

  def parse(<<255, payload::binary>>, _delta_sum, options) do
    {options, payload}
  end

  def parse(<<delta::size(4), len::size(4), rest::binary>>, sum, options) do
    {option_number, rest} = parse_number(delta, sum, rest)
    {option_length, rest} = parse_length(len, rest)
    {option, rest} = parse_value(option_length, rest)

    case option do
      <<0>> -> parse(rest, option_number, options)
      _ -> parse(rest, option_number, options ++ [{Opts.name(option_number), option}])
    end
  end

  @spec parse_number(integer(), integer(), binary()) :: {integer(), binary()}
  def parse_number(delta, sum, bin) when delta < 13 do
    {delta + sum, bin}
  end

  def parse_number(13, sum, bin) do
    <<delta, rest::binary>> = bin
    {delta + sum + 13, rest}
  end

  def parse_number(14, sum, bin) do
    <<delta::size(16), rest::binary>> = bin
    {delta + sum + 269, rest}
  end

  @spec parse_length(integer(), binary()) :: {integer(), binary()}
  def parse_length(len, bin) when len < 13 do
    {len, bin}
  end

  def parse_length(13, bin) do
    <<len, rest::binary>> = bin
    {len + 13, rest}
  end

  def parse_length(14, bin) do
    <<len, rest::binary>> = bin
    {len + 269, rest}
  end

  def parse_value(len, bin) do
    <<value::binary-size(len), rest::binary>> = bin
    {value, rest}
  end
end
