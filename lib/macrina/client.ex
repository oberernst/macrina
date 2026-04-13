defmodule Macrina.Client do
  alias Macrina.{Connection.Server, Endpoint, Request, Response, Telemetry}

  defstruct [:conn, :ip, :port]

  def connect(opts) when is_list(opts), do: new(opts)

  def new(opts) when is_list(opts) do
    ip = Keyword.fetch!(opts, :ip)
    port = Keyword.fetch!(opts, :port)
    endpoint = Keyword.get(opts, :endpoint, Endpoint)
    build(ip, port, endpoint)
  end

  def build(ip, port, endpoint \\ Endpoint) do
    {:ok, socket} = Endpoint.socket(endpoint)
    {:ok, handler} = Endpoint.handler(endpoint)

    case Server.start_link(handler: handler, ip: ip, port: port, socket: socket, type: :client) do
      {:ok, conn} -> %__MODULE__{conn: conn, ip: ip, port: port}
      {:error, {:already_started, conn}} -> %__MODULE__{conn: conn, ip: ip, port: port}
    end
  end

  def request(%__MODULE__{conn: pid, ip: ip, port: port}, %Request{} = request) do
    Telemetry.span(
      [:client, :request],
      %{method: request.method, path: request.path, peer: %{ip: ip, port: port}},
      fn ->
        response =
          request
          |> Request.to_message()
          |> Server.call(pid)
          |> Response.from_message()

        {response, %{code: response.code, type: response.type}}
      end
    )
  end

  def get(%__MODULE__{} = client, uri) when is_binary(uri) do
    request(client, Request.from_uri(:get, uri, type: :con))
  end

  def post(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request(client, Request.from_uri(:post, uri, payload: payload, type: :con))
  end

  def put(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request(client, Request.from_uri(:put, uri, payload: payload, type: :con))
  end

  def delete(%__MODULE__{} = client, uri) when is_binary(uri) do
    request(client, Request.from_uri(:delete, uri, type: :con))
  end
end
