defmodule Macrina.Client do
  alias Macrina.{
    Blockwise,
    Connection.Server,
    Endpoint,
    Message,
    Message.Opts.Block,
    Observe.Subscription,
    Request,
    Response,
    Telemetry
  }

  defstruct [:conn, :ip, :port]

  def connect(opts) when is_list(opts) do
    new(opts)
  end

  def connect!(opts) when is_list(opts) do
    case connect(opts) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "invalid client options: #{inspect(reason)}"
    end
  end

  def new(opts) when is_list(opts) do
    with {:ok, ip} <- fetch_opt(opts, :ip),
         {:ok, port} <- fetch_opt(opts, :port) do
      endpoint = Keyword.get(opts, :endpoint, Endpoint)
      build(ip, port, endpoint)
    end
  end

  def new!(opts) when is_list(opts) do
    case new(opts) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "invalid client options: #{inspect(reason)}"
    end
  end

  def build(ip, port, endpoint \\ Endpoint) do
    with {:ok, socket} <- Endpoint.socket(endpoint),
         {:ok, handler} <- Endpoint.handler(endpoint),
         {:ok, conn} <- start_connection(handler, ip, port, socket) do
      client = %__MODULE__{conn: conn, ip: ip, port: port}
      {:ok, client}
    end
  end

  def build!(ip, port, endpoint \\ Endpoint) do
    case build(ip, port, endpoint) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "failed to build client: #{inspect(reason)}"
    end
  end

  def request(%__MODULE__{conn: pid, ip: ip, port: port}, %Request{} = request) do
    metadata = %{method: request.method, path: request.path, peer: %{ip: ip, port: port}}

    Telemetry.span([:client, :request], metadata, fn ->
      result = do_request(pid, request)
      stop_metadata = telemetry_result_metadata(result)

      {result, stop_metadata}
    end)
  end

  def request!(%__MODULE__{} = client, %Request{} = request) do
    case request(client, request) do
      {:ok, response} -> response
      {:error, reason} -> raise RuntimeError, "client request failed: #{inspect(reason)}"
    end
  end

  def observe(client, request_or_uri, opts \\ [])

  def observe(%__MODULE__{} = client, %Request{} = request, opts) when is_list(opts) do
    notify_to = Keyword.get(opts, :notify_to, self())
    observe_request = put_initial_observe(request)
    metadata = observe_metadata(client, observe_request)

    Telemetry.span([:client, :request], metadata, fn ->
      result = do_observe(client.conn, observe_request, notify_to)
      {result, telemetry_result_metadata(result)}
    end)
  end

  def observe(%__MODULE__{} = client, uri, opts) when is_binary(uri) and is_list(opts) do
    {notify_to, request_opts} = Keyword.pop(opts, :notify_to, self())

    with {:ok, request} <- Request.from_uri(:get, uri, request_opts) do
      observe(client, request, notify_to: notify_to)
    end
  end

  def observe!(%__MODULE__{} = client, request_or_uri, opts \\ []) do
    case observe(client, request_or_uri, opts) do
      {:ok, subscription, response} -> {subscription, response}
      {:error, reason} -> raise RuntimeError, "client observe failed: #{inspect(reason)}"
    end
  end

  def cancel_observe(%Subscription{} = subscription) do
    cancel_request = observe_cancel_request(subscription)

    with {:ok, message} <- Request.to_message(cancel_request),
         {:ok, response_message} <- call_server(subscription.connection, message),
         :ok <- Server.observe_unsubscribe(subscription.connection, subscription.token) do
      {:ok, Response.from_message(response_message)}
    end
  end

  def cancel_observe!(%Subscription{} = subscription) do
    case cancel_observe(subscription) do
      {:ok, response} -> response
      {:error, reason} -> raise RuntimeError, "client observe cancel failed: #{inspect(reason)}"
    end
  end

  def get(%__MODULE__{} = client, uri) when is_binary(uri) do
    request_uri(client, :get, uri, type: :con)
  end

  def get!(%__MODULE__{} = client, uri) when is_binary(uri) do
    request!(client, Request.from_uri!(:get, uri, type: :con))
  end

  def post(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request_uri(client, :post, uri, payload: payload, type: :con)
  end

  def post!(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request!(client, Request.from_uri!(:post, uri, payload: payload, type: :con))
  end

  def put(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request_uri(client, :put, uri, payload: payload, type: :con)
  end

  def put!(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request!(client, Request.from_uri!(:put, uri, payload: payload, type: :con))
  end

  def delete(%__MODULE__{} = client, uri) when is_binary(uri) do
    request_uri(client, :delete, uri, type: :con)
  end

  def delete!(%__MODULE__{} = client, uri) when is_binary(uri) do
    request!(client, Request.from_uri!(:delete, uri, type: :con))
  end

  defp request_uri(client, method, uri, opts) do
    with {:ok, request} <- Request.from_uri(method, uri, opts) do
      request(client, request)
    end
  end

  defp do_observe(pid, %Request{} = request, notify_to) when is_pid(notify_to) do
    with {:ok, message} <- Request.to_message(request),
         {:ok, response_message} <- call_server(pid, message),
         {:ok, final_response_message} <-
           maybe_collect_block2(pid, request, response_message, %{}),
         response = Response.from_message(final_response_message),
         observe when is_integer(observe) and observe >= 0 <- Response.observe(response),
         subscription <- build_observe_subscription(pid, request, message, notify_to),
         :ok <- Server.observe_subscribe(pid, subscription, observe) do
      {:ok, subscription, response}
    else
      nil -> {:error, :observe_not_supported}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_observe_subscription(pid, %Request{} = request, %Message{} = message, notify_to) do
    subscription_request = %Request{request | id: nil, token: message.token}

    %Subscription{
      connection: pid,
      notify_to: notify_to,
      path: request.path,
      request: subscription_request,
      token: message.token
    }
  end

  defp observe_cancel_request(%Subscription{request: request, token: token}) do
    options =
      request.options
      |> Enum.reject(fn {name, _value} -> name in ["Observe", "Block2"] end)

    request
    |> then(fn next_request ->
      %Request{next_request | id: nil, options: options, token: token}
    end)
    |> Request.put_observe(1)
  end

  defp observe_metadata(%__MODULE__{ip: ip, port: port}, %Request{} = request) do
    %{method: request.method, path: request.path, peer: %{ip: ip, port: port}}
  end

  defp put_initial_observe(%Request{} = request) do
    case Request.observe(request) do
      0 -> request
      _other -> Request.put_observe(request, 0)
    end
  end

  defp do_request(pid, request) do
    with {:ok, message} <- Request.to_message(request),
         {:ok, response_message} <- call_server(pid, message),
         {:ok, final_response_message} <-
           maybe_collect_block2(pid, request, response_message, %{}) do
      response = Response.from_message(final_response_message)
      {:ok, response}
    end
  end

  defp maybe_collect_block2(pid, %Request{} = request, %Message{} = response_message, transfers) do
    if is_nil(Request.block2(request)) do
      maybe_collect_implicit_block2(pid, request, response_message, transfers)
    else
      {:ok, response_message}
    end
  end

  defp maybe_collect_implicit_block2(
         _pid,
         _request,
         %Message{descriptive_block: nil} = response_message,
         _transfers
       ) do
    {:ok, response_message}
  end

  defp maybe_collect_implicit_block2(
         pid,
         request,
         %Message{descriptive_block: %Block{more: more}} = response_message,
         transfers
       ) do
    with {:ok, next_transfers} <- Blockwise.put_transfer(transfers, response_message) do
      if more do
        next_request = next_block2_request(request, response_message)

        with {:ok, next_message} <- Request.to_message(next_request),
             {:ok, next_response_message} <- call_server(pid, next_message) do
          maybe_collect_block2(pid, request, next_response_message, next_transfers)
        end
      else
        finalize_block2_response(next_transfers, response_message)
      end
    else
      {:error, reason} -> {:error, {:invalid_block2_response, reason}}
    end
  end

  defp finalize_block2_response(transfers, response_message) do
    case Blockwise.assemble(transfers, response_message) do
      {:ok, payload, _metadata} ->
        {:ok, %{response_message | payload: payload}}

      {:error, :missing_block, _metadata} ->
        {:error, {:invalid_block2_response, :missing_block}}

      :error ->
        {:error, {:invalid_block2_response, :missing_block}}
    end
  end

  defp next_block2_request(%Request{} = request, %{
         descriptive_block: %Block{} = block,
         token: token
       }) do
    next_block = %Block{number: block.number + 1, more: false, size: block.size}

    request
    |> Request.put_block2(next_block)
    |> then(fn next_request -> %Request{next_request | id: nil, token: token} end)
  end

  defp call_server(pid, message) do
    if Process.alive?(pid) do
      Server.call(pid, message)
    else
      {:error, {:connection_unavailable, pid}}
    end
  end

  defp start_connection(handler, ip, port, socket) do
    case Server.start_link(handler: handler, ip: ip, port: port, socket: socket, type: :client) do
      {:ok, conn} -> {:ok, conn}
      {:error, {:already_started, conn}} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp telemetry_result_metadata({:ok, response}) do
    %{code: response.code, status: :ok, type: response.type}
  end

  defp telemetry_result_metadata({:ok, _subscription, response}) do
    %{code: response.code, status: :ok, type: response.type}
  end

  defp telemetry_result_metadata({:error, reason}) do
    %{error: reason, status: :error}
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end
end
