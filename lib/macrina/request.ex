defmodule Macrina.Request do
  alias Macrina.Message

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
          type: :ack | :con | :non | :res
        }

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

    if parsed.fragment do
      raise ArgumentError, "CoAP request URIs must not include a fragment"
    end

    scheme = parse_scheme(parsed.scheme)

    new(
      method,
      Keyword.merge(opts,
        host: normalize_host(parsed.host),
        path: parse_path(parsed.path),
        port: normalize_port(parsed, scheme),
        query: parse_query(parsed.query),
        scheme: scheme
      )
    )
  end

  def to_message(%__MODULE__{} = request) do
    Message.build(request.method,
      id: request.id,
      options: to_options(request),
      payload: request.payload,
      token: request.token,
      type: request.type
    )
  end

  def to_options(%__MODULE__{} = request) do
    host_options =
      case request.host do
        nil -> []
        host -> [{"Uri-Host", host}]
      end

    port_options =
      case request.port do
        nil -> []
        port -> [{"Uri-Port", port}]
      end

    port_options =
      if port_options == [{"Uri-Port", default_port(request.scheme)}] do
        []
      else
        port_options
      end

    path_options = Enum.map(request.path, &{"Uri-Path", &1})
    query_options = Enum.map(request.query, &{"Uri-Query", &1})

    host_options ++ port_options ++ path_options ++ query_options ++ request.options
  end

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

  defp parse_scheme(nil), do: :coap
  defp parse_scheme("coap"), do: :coap
  defp parse_scheme("coaps"), do: :coaps

  defp parse_scheme(scheme) do
    raise ArgumentError, "unsupported CoAP scheme: #{inspect(scheme)}"
  end
end
