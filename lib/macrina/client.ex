defmodule Macrina.Client do
  @moduledoc """
  CoAP client.

  Provides a connection-oriented client API for sending CoAP requests and
  managing Observe subscriptions. Each client struct wraps a
  `Macrina.Peer.Session` process that handles retransmission, block
  transfers, and observe notifications for a single remote peer.

  ## Connecting

      {:ok, client} = Macrina.Client.connect(ip: {127, 0, 0, 1}, port: 5683)

  ## Requests

      {:ok, response} = Macrina.Client.get(client, "/temperature")
      {:ok, response} = Macrina.Client.post(client, "/config", "new-value")

  Or with a `Macrina.Request` struct for full control:

      request = Macrina.Request.from_uri!(:get, "/sensors/temp",
        accept: :application_json
      )
      {:ok, response} = Macrina.Client.request(client, request)

  Block2 (download) responses are reassembled automatically unless the
  request explicitly sets a `Block2` option.

  ## Observe

      {:ok, subscription, initial} =
        Macrina.Client.observe(client, request, notify_to: self())

      receive do
        {:macrina_observe, ^subscription, notification} ->
          notification.payload
      end

      :ok = Macrina.Client.cancel_observe(subscription)

  Notifications arrive as `{:macrina_observe, subscription, response}`
  messages to the process specified by `:notify_to` (defaults to `self()`).
  """

  alias Macrina.{
    Blockwise,
    Message,
    Message.Opts.Block,
    Observe.Subscription,
    Peer.Session,
    Request,
    Response,
    Telemetry,
    Transport.UDP
  }

  defstruct [:conn, :ip, :port]

  @doc """
  Connects to a remote CoAP peer.

  Accepts `:ip`, `:port`, and an optional `:endpoint` (defaults to
  `Macrina.Transport.UDP`). Returns `{:ok, client}` or `{:error, reason}`.
  """
  def connect(opts) when is_list(opts) do
    new(opts)
  end

  @doc "Like `connect/1` but raises on failure."
  def connect!(opts) when is_list(opts) do
    case connect(opts) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "invalid client options: #{inspect(reason)}"
    end
  end

  @doc false
  def new(opts) when is_list(opts) do
    with {:ok, ip} <- fetch_opt(opts, :ip),
         {:ok, port} <- fetch_opt(opts, :port) do
      endpoint = Keyword.get(opts, :endpoint, UDP)
      build(ip, port, endpoint)
    end
  end

  @doc false
  def new!(opts) when is_list(opts) do
    case new(opts) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "invalid client options: #{inspect(reason)}"
    end
  end

  @doc false
  def build(ip, port, endpoint \\ UDP) do
    with {:ok, socket} <- UDP.socket(endpoint),
         {:ok, handler} <- UDP.handler(endpoint),
         {:ok, conn} <- start_connection(handler, ip, port, socket) do
      client = %__MODULE__{conn: conn, ip: ip, port: port}
      {:ok, client}
    end
  end

  @doc false
  def build!(ip, port, endpoint \\ UDP) do
    case build(ip, port, endpoint) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "failed to build client: #{inspect(reason)}"
    end
  end

  @doc """
  Sends a `Macrina.Request` and returns `{:ok, response}` or `{:error, reason}`.

  Block2 responses are reassembled automatically unless the request sets
  `Block2` explicitly.
  """
  def request(%__MODULE__{conn: pid, ip: ip, port: port}, %Request{} = request) do
    metadata = %{method: request.method, path: request.path, peer: %{ip: ip, port: port}}

    Telemetry.span([:client, :request], metadata, fn ->
      result = do_request(pid, request)
      stop_metadata = telemetry_result_metadata(result)

      {result, stop_metadata}
    end)
  end

  @doc "Like `request/2` but raises on failure."
  def request!(%__MODULE__{} = client, %Request{} = request) do
    case request(client, request) do
      {:ok, response} -> response
      {:error, reason} -> raise RuntimeError, "client request failed: #{inspect(reason)}"
    end
  end

  @doc """
  Registers an observe relationship for the given request.

  Returns `{:ok, subscription, initial_response}` on success. Subsequent
  server notifications arrive as `{:macrina_observe, subscription, response}`
  messages to the `:notify_to` process (defaults to `self()`).

  Accepts either a `Macrina.Request` struct or a URI string.
  """
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

  @doc "Like `observe/3` but raises on failure."
  def observe!(%__MODULE__{} = client, request_or_uri, opts \\ []) do
    case observe(client, request_or_uri, opts) do
      {:ok, subscription, response} -> {subscription, response}
      {:error, reason} -> raise RuntimeError, "client observe failed: #{inspect(reason)}"
    end
  end

  @doc """
  Cancels an active observe subscription.

  Sends an observe-cancel request to the server and unregisters the
  local subscription. Returns `{:ok, response}` or `{:error, reason}`.
  """
  def cancel_observe(%Subscription{} = subscription) do
    cancel_request = observe_cancel_request(subscription)

    with {:ok, message} <- Request.to_message(cancel_request),
         {:ok, response_message} <- call_server(subscription.connection, message),
         :ok <- Session.observe_unsubscribe(subscription.connection, subscription.token) do
      {:ok, Response.from_message(response_message)}
    end
  end

  @doc "Like `cancel_observe/1` but raises on failure."
  def cancel_observe!(%Subscription{} = subscription) do
    case cancel_observe(subscription) do
      {:ok, response} -> response
      {:error, reason} -> raise RuntimeError, "client observe cancel failed: #{inspect(reason)}"
    end
  end

  @doc "Sends a confirmable GET request to the given URI."
  def get(%__MODULE__{} = client, uri) when is_binary(uri) do
    request_uri(client, :get, uri, type: :con)
  end

  def get!(%__MODULE__{} = client, uri) when is_binary(uri) do
    request!(client, Request.from_uri!(:get, uri, type: :con))
  end

  @doc "Sends a confirmable POST request with optional payload."
  def post(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request_uri(client, :post, uri, payload: payload, type: :con)
  end

  def post!(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request!(client, Request.from_uri!(:post, uri, payload: payload, type: :con))
  end

  @doc "Sends a confirmable PUT request with optional payload."
  def put(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request_uri(client, :put, uri, payload: payload, type: :con)
  end

  def put!(%__MODULE__{} = client, uri, payload \\ <<>>) when is_binary(uri) do
    request!(client, Request.from_uri!(:put, uri, payload: payload, type: :con))
  end

  @doc "Sends a confirmable DELETE request to the given URI."
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
         :ok <- Session.observe_subscribe(pid, subscription, observe) do
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
    options = Enum.reject(request.options, fn {name, _} -> name in ["Observe", "Block2"] end)

    %Request{request | id: nil, options: options, token: token}
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
    next_request = Request.put_block2(request, next_block)
    %Request{next_request | id: nil, token: token}
  end

  defp call_server(pid, message) do
    if Process.alive?(pid) do
      Session.call(pid, message)
    else
      {:error, {:connection_unavailable, pid}}
    end
  end

  defp start_connection(handler, ip, port, socket) do
    case Session.start_link(handler: handler, ip: ip, port: port, socket: socket, type: :client) do
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
