defmodule Macrina.Request do
  alias Macrina.Message

  @path_option "Uri-Path"
  @query_option "Uri-Query"
  @host_option "Uri-Host"
  @port_option "Uri-Port"

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
    %__MODULE__{
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

    host_options ++ port_options ++ path_options ++ query_options ++ request.options
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
end
