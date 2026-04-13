defmodule Macrina.Request do
  alias Macrina.{ContentFormat, Message, Message.Opts.Block}

  @path_option "Uri-Path"
  @query_option "Uri-Query"
  @host_option "Uri-Host"
  @port_option "Uri-Port"
  @accept_option "Accept"
  @block1_option "Block1"
  @block2_option "Block2"
  @content_format_option "Content-Format"
  @observe_option "Observe"

  @enforce_keys [:method]
  defstruct host: nil,
            id: nil,
            method: nil,
            options: [],
            path: [],
            payload: <<>>,
            port: nil,
            query: [],
            scheme: :coap,
            token: nil,
            type: :con

  @type t :: %__MODULE__{
          host: nil | String.t(),
          id: nil | non_neg_integer(),
          method: atom(),
          options: [{String.t(), term()}],
          path: [String.t()],
          payload: binary(),
          port: nil | pos_integer(),
          query: [String.t()],
          scheme: :coap | :coaps,
          token: nil | binary(),
          type: :ack | :con | :non | :rst
        }

  @type uri_error :: {:invalid_uri, :fragment_not_allowed} | {:unsupported_scheme, String.t()}
  @type message_error :: {:invalid_request, term()}

  def new(method, opts \\ []) when is_atom(method) and is_list(opts) do
    request = %__MODULE__{
      method: method,
      host: Keyword.get(opts, :host),
      id: Keyword.get(opts, :id),
      options: Keyword.get(opts, :options, []),
      path: Keyword.get(opts, :path, []),
      payload: Keyword.get(opts, :payload, <<>>),
      port: Keyword.get(opts, :port),
      query: Keyword.get(opts, :query, []),
      scheme: Keyword.get(opts, :scheme, :coap),
      token: Keyword.get(opts, :token),
      type: Keyword.get(opts, :type, :con)
    }

    request
    |> maybe_put_content_format(Keyword.fetch(opts, :content_format))
    |> maybe_put_accept(Keyword.fetch(opts, :accept))
    |> maybe_put_observe(Keyword.fetch(opts, :observe))
    |> maybe_put_block1(Keyword.fetch(opts, :block1))
    |> maybe_put_block2(Keyword.fetch(opts, :block2))
  end

  def from_uri(method, uri, opts \\ [])
      when is_atom(method) and is_binary(uri) and is_list(opts) do
    parsed = URI.parse(uri)

    with :ok <- validate_no_fragment(parsed),
         {:ok, scheme} <- parse_scheme(parsed.scheme) do
      request_opts = uri_request_opts(parsed, scheme, opts)
      request = new(method, request_opts)

      {:ok, request}
    end
  end

  def from_uri!(method, uri, opts \\ [])
      when is_atom(method) and is_binary(uri) and is_list(opts) do
    case from_uri(method, uri, opts) do
      {:ok, request} -> request
      {:error, reason} -> raise ArgumentError, "invalid CoAP request URI: #{inspect(reason)}"
    end
  end

  def from_message(%Message{} = message) do
    {host, port, path, query, options} = split_options(message.options)

    request = %__MODULE__{
      host: host,
      id: message.id,
      method: message.code,
      options: options,
      path: path,
      payload: message.payload,
      port: port,
      query: query,
      scheme: :coap,
      token: message.token,
      type: message.type
    }

    {:ok, request}
  end

  def to_message(%__MODULE__{} = request) do
    options = to_options(request)

    case Message.build(request.method,
           id: request.id,
           options: options,
           payload: request.payload,
           token: request.token,
           type: request.type
         ) do
      {:ok, message} ->
        {:ok, message}

      {:error, :invalid_code} ->
        {:error, {:invalid_request, {:unsupported_code, request.method}}}

      {:error, reason} ->
        {:error, {:invalid_request, reason}}
    end
  end

  def to_message!(%__MODULE__{} = request) do
    case to_message(request) do
      {:ok, message} -> message
      {:error, reason} -> raise ArgumentError, "invalid CoAP request: #{inspect(reason)}"
    end
  end

  def to_options(%__MODULE__{} = request) do
    host_options = host_options(request.host)
    port_options = port_options(request.port, request.scheme)
    path_options = Enum.map(request.path, &{@path_option, &1})
    query_options = Enum.map(request.query, &{@query_option, &1})
    typed_options = normalize_typed_options(request.options)

    host_options ++ port_options ++ path_options ++ query_options ++ typed_options
  end

  def content_format(%__MODULE__{options: options}) do
    decode_content_format_option(option_value(options, @content_format_option))
  end

  def accept(%__MODULE__{options: options}) do
    decode_content_format_option(option_value(options, @accept_option))
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

  def put_content_format(%__MODULE__{options: options} = request, content_format) do
    next_options = put_option(options, @content_format_option, content_format)
    %__MODULE__{request | options: next_options}
  end

  def put_accept(%__MODULE__{options: options} = request, accept) do
    next_options = put_option(options, @accept_option, accept)
    %__MODULE__{request | options: next_options}
  end

  def put_observe(%__MODULE__{options: options} = request, observe)
      when is_integer(observe) and observe >= 0 do
    next_options = put_option(options, @observe_option, observe)
    %__MODULE__{request | options: next_options}
  end

  def put_block1(%__MODULE__{options: options} = request, %Block{} = block) do
    next_options = put_option(options, @block1_option, block)
    %__MODULE__{request | options: next_options}
  end

  def put_block2(%__MODULE__{options: options} = request, %Block{} = block) do
    next_options = put_option(options, @block2_option, block)
    %__MODULE__{request | options: next_options}
  end

  defp uri_request_opts(parsed, scheme, opts) do
    uri_opts = [
      host: normalize_host(parsed.host),
      path: parse_path(parsed.path),
      port: normalize_port(parsed, scheme),
      query: parse_query(parsed.query),
      scheme: scheme
    ]

    Keyword.merge(opts, uri_opts)
  end

  defp host_options(nil), do: []
  defp host_options(host), do: [{@host_option, host}]

  defp port_options(nil, _scheme), do: []

  defp port_options(port, scheme) do
    if port == default_port(scheme) do
      []
    else
      [{@port_option, port}]
    end
  end

  defp split_options(options) do
    Enum.reduce(options, {nil, nil, [], [], []}, fn
      {@host_option, value}, {_host, port, path, query, acc} ->
        {value, port, path, query, acc}

      {@port_option, value}, {host, _port, path, query, acc} ->
        {host, value, path, query, acc}

      {@path_option, value}, {host, port, path, query, acc} ->
        {host, port, path ++ [value], query, acc}

      {@query_option, value}, {host, port, path, query, acc} ->
        {host, port, path, query ++ [value], acc}

      option, {host, port, path, query, acc} ->
        {host, port, path, query, acc ++ [option]}
    end)
  end

  defp validate_no_fragment(%URI{fragment: nil}), do: :ok
  defp validate_no_fragment(%URI{}), do: {:error, {:invalid_uri, :fragment_not_allowed}}

  defp default_port(:coap), do: 5683
  defp default_port(:coaps), do: 5684

  defp normalize_host(nil), do: nil
  defp normalize_host(host), do: String.downcase(host)

  defp normalize_port(%URI{scheme: nil, host: nil, port: nil}, _scheme), do: nil
  defp normalize_port(%URI{port: nil}, scheme), do: default_port(scheme)
  defp normalize_port(%URI{port: port}, _scheme), do: port

  defp parse_path(nil), do: []
  defp parse_path(""), do: []
  defp parse_path("/"), do: []

  defp parse_path(path) do
    path
    |> String.trim_leading("/")
    |> String.split("/", trim: false)
    |> Enum.map(&URI.decode/1)
  end

  defp parse_query(nil), do: []
  defp parse_query(""), do: []

  defp parse_query(query) do
    query
    |> String.split("&", trim: false)
    |> Enum.map(&URI.decode/1)
  end

  defp parse_scheme(nil), do: {:ok, :coap}
  defp parse_scheme("coap"), do: {:ok, :coap}
  defp parse_scheme("coaps"), do: {:ok, :coaps}
  defp parse_scheme(scheme), do: {:error, {:unsupported_scheme, scheme}}

  defp maybe_put_content_format(request, {:ok, content_format}) do
    put_content_format(request, content_format)
  end

  defp maybe_put_content_format(request, :error) do
    request
  end

  defp maybe_put_accept(request, {:ok, accept}) do
    put_accept(request, accept)
  end

  defp maybe_put_accept(request, :error) do
    request
  end

  defp maybe_put_observe(request, {:ok, observe}) do
    put_observe(request, observe)
  end

  defp maybe_put_observe(request, :error) do
    request
  end

  defp maybe_put_block1(request, {:ok, %Block{} = block}) do
    put_block1(request, block)
  end

  defp maybe_put_block1(request, :error) do
    request
  end

  defp maybe_put_block2(request, {:ok, %Block{} = block}) do
    put_block2(request, block)
  end

  defp maybe_put_block2(request, :error) do
    request
  end

  defp option_value(options, name) do
    case List.keyfind(options, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp put_option(options, name, value) do
    next_options = Enum.reject(options, fn {option_name, _value} -> option_name == name end)
    next_options ++ [{name, value}]
  end

  defp normalize_typed_options(options) do
    Enum.map(options, &normalize_typed_option/1)
  end

  defp normalize_typed_option({name, value})
       when name in [@accept_option, @content_format_option] do
    case ContentFormat.encode(value) do
      {:ok, encoded_value} -> {name, encoded_value}
      :error -> {name, value}
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
