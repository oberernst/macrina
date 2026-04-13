defmodule Macrina.Response do
  alias Macrina.{ContentFormat, Message, Message.Opts.Block}

  @location_path_option "Location-Path"
  @location_query_option "Location-Query"
  @content_format_option "Content-Format"
  @max_age_option "Max-Age"
  @observe_option "Observe"
  @block1_option "Block1"
  @block2_option "Block2"

  defstruct [:code, :control_block, :descriptive_block, :id, :options, :payload, :token, :type]

  @type t :: %__MODULE__{
          code: atom(),
          control_block: term(),
          descriptive_block: term(),
          id: non_neg_integer(),
          options: [{String.t(), term()}],
          payload: binary(),
          token: binary(),
          type: :ack | :con | :non | :rst
        }

  def new(code, opts \\ []) when is_atom(code) and is_list(opts) do
    response = %__MODULE__{
      code: code,
      control_block: Keyword.get(opts, :control_block),
      descriptive_block: Keyword.get(opts, :descriptive_block),
      id: Keyword.get(opts, :id),
      options: Keyword.get(opts, :options, []),
      payload: Keyword.get(opts, :payload, <<>>),
      token: Keyword.get(opts, :token, <<>>),
      type: Keyword.get(opts, :type, :ack)
    }

    response
    |> maybe_put_content_format(Keyword.fetch(opts, :content_format))
    |> maybe_put_location_path(Keyword.fetch(opts, :location_path))
    |> maybe_put_location_query(Keyword.fetch(opts, :location_query))
    |> maybe_put_max_age(Keyword.fetch(opts, :max_age))
    |> maybe_put_observe(Keyword.fetch(opts, :observe))
    |> maybe_put_block1(Keyword.fetch(opts, :block1))
    |> maybe_put_block2(Keyword.fetch(opts, :block2))
  end

  def from_message(%Message{} = message) do
    %__MODULE__{
      code: message.code,
      control_block: message.control_block,
      descriptive_block: message.descriptive_block,
      id: message.id,
      options: message.options,
      payload: message.payload,
      token: message.token,
      type: message.type
    }
  end

  def to_message(%__MODULE__{} = response, %Message{} = request_message) do
    options = normalize_typed_options(response.options)

    case Message.response(request_message,
           code: response.code,
           options: options,
           payload: response.payload,
           type: response.type
         ) do
      {:ok, message} ->
        {:ok, message}

      {:error, :invalid_code} ->
        {:error, {:invalid_response, {:unsupported_code, response.code}}}

      {:error, reason} ->
        {:error, {:invalid_response, reason}}
    end
  end

  def to_message(%__MODULE__{} = response, nil) do
    options = normalize_typed_options(response.options)

    case Message.build(response.code,
           id: response.id,
           options: options,
           payload: response.payload,
           token: response.token,
           type: response.type
         ) do
      {:ok, message} ->
        {:ok, message}

      {:error, :invalid_code} ->
        {:error, {:invalid_response, {:unsupported_code, response.code}}}

      {:error, reason} ->
        {:error, {:invalid_response, reason}}
    end
  end

  def to_message!(%__MODULE__{} = response, request_message \\ nil) do
    case to_message(response, request_message) do
      {:ok, message} -> message
      {:error, reason} -> raise ArgumentError, "invalid CoAP response: #{inspect(reason)}"
    end
  end

  def content_format(%__MODULE__{options: options}) do
    decode_content_format_option(option_value(options, @content_format_option))
  end

  def location_path(%__MODULE__{options: options}) do
    option_values(options, @location_path_option)
  end

  def location_query(%__MODULE__{options: options}) do
    option_values(options, @location_query_option)
  end

  def max_age(%__MODULE__{options: options}) do
    option_value(options, @max_age_option)
  end

  def observe(%__MODULE__{options: options}) do
    option_value(options, @observe_option)
  end

  def block1(%__MODULE__{options: options}) do
    option_value(options, @block1_option)
  end

  def block2(%__MODULE__{options: options}) do
    option_value(options, @block2_option)
  end

  def put_content_format(%__MODULE__{options: options} = response, content_format) do
    next_options = put_option(options, @content_format_option, content_format)
    %__MODULE__{response | options: next_options}
  end

  def put_location_path(%__MODULE__{options: options} = response, location_path)
      when is_list(location_path) do
    next_options = put_repeated_option(options, @location_path_option, location_path)
    %__MODULE__{response | options: next_options}
  end

  def put_location_query(%__MODULE__{options: options} = response, location_query)
      when is_list(location_query) do
    next_options = put_repeated_option(options, @location_query_option, location_query)
    %__MODULE__{response | options: next_options}
  end

  def put_max_age(%__MODULE__{options: options} = response, max_age) do
    next_options = put_option(options, @max_age_option, max_age)
    %__MODULE__{response | options: next_options}
  end

  def put_observe(%__MODULE__{options: options} = response, observe)
      when is_integer(observe) and observe >= 0 do
    next_options = put_option(options, @observe_option, observe)
    %__MODULE__{response | options: next_options}
  end

  def put_block1(%__MODULE__{options: options} = response, %Block{} = block) do
    next_options = put_option(options, @block1_option, block)
    %__MODULE__{response | options: next_options}
  end

  def put_block2(%__MODULE__{options: options} = response, %Block{} = block) do
    next_options = put_option(options, @block2_option, block)
    %__MODULE__{response | options: next_options}
  end

  defp maybe_put_content_format(response, {:ok, content_format}) do
    put_content_format(response, content_format)
  end

  defp maybe_put_content_format(response, :error) do
    response
  end

  defp maybe_put_location_path(response, {:ok, location_path}) do
    put_location_path(response, location_path)
  end

  defp maybe_put_location_path(response, :error) do
    response
  end

  defp maybe_put_location_query(response, {:ok, location_query}) do
    put_location_query(response, location_query)
  end

  defp maybe_put_location_query(response, :error) do
    response
  end

  defp maybe_put_max_age(response, {:ok, max_age}) do
    put_max_age(response, max_age)
  end

  defp maybe_put_max_age(response, :error) do
    response
  end

  defp maybe_put_observe(response, {:ok, observe}) do
    put_observe(response, observe)
  end

  defp maybe_put_observe(response, :error) do
    response
  end

  defp maybe_put_block1(response, {:ok, %Block{} = block}) do
    put_block1(response, block)
  end

  defp maybe_put_block1(response, :error) do
    response
  end

  defp maybe_put_block2(response, {:ok, %Block{} = block}) do
    put_block2(response, block)
  end

  defp maybe_put_block2(response, :error) do
    response
  end

  defp option_value(options, name) do
    case List.keyfind(options, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp option_values(options, name) do
    for {^name, value} <- options do
      value
    end
  end

  defp put_option(options, name, value) do
    next_options = Enum.reject(options, fn {option_name, _value} -> option_name == name end)
    next_options ++ [{name, value}]
  end

  defp put_repeated_option(options, name, values) do
    next_options = Enum.reject(options, fn {option_name, _value} -> option_name == name end)
    repeated_options = Enum.map(values, &{name, &1})
    next_options ++ repeated_options
  end

  defp normalize_typed_options(options) do
    Enum.map(options, &normalize_typed_option/1)
  end

  defp normalize_typed_option({@content_format_option, value}) do
    case ContentFormat.encode(value) do
      {:ok, encoded_value} -> {@content_format_option, encoded_value}
      :error -> {@content_format_option, value}
    end
  end

  defp normalize_typed_option(option) do
    option
  end

  defp decode_content_format_option(nil) do
    nil
  end

  defp decode_content_format_option(value) do
    case ContentFormat.decode(value) do
      {:ok, decoded_value} -> decoded_value
      :error -> value
    end
  end
end
