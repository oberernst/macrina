defmodule Macrina.Server do
  alias Macrina.{Block1, Endpoint, Observe, Response, Router}
  alias Macrina.Connection.Server, as: ConnectionServer

  def start_link(opts) when is_list(opts) do
    with {:ok, endpoint_opts} <- build_endpoint_opts(opts) do
      Endpoint.start_link(endpoint_opts)
    end
  end

  def start_link!(opts) when is_list(opts) do
    case start_link(opts) do
      {:ok, pid} -> pid
      {:error, reason} -> raise ArgumentError, "invalid server start options: #{inspect(reason)}"
    end
  end

  def notify(server, path, %Response{} = response) do
    with {:ok, endpoint} <- resolve_endpoint(server),
         {:ok, notifications} <- Observe.notifications(endpoint, path) do
      Enum.each(notifications, fn notification ->
        ConnectionServer.notify_observer(notification.connection, notification, response)
      end)

      {:ok, length(notifications)}
    end
  end

  def notify!(server, path, %Response{} = response) do
    case notify(server, path, response) do
      {:ok, count} -> count
      {:error, reason} -> raise ArgumentError, "failed to notify observers: #{inspect(reason)}"
    end
  end

  defp build_endpoint_opts(opts) do
    handler = Keyword.get(opts, :handler)
    router = Keyword.get(opts, :router)
    context = Keyword.get(opts, :context, %{})

    cond do
      handler ->
        opts
        |> endpoint_opts(handler)
        |> normalize_block1_opts(:handler)

      router ->
        router_handler = {:router, router, context}

        opts
        |> endpoint_opts(router_handler)
        |> normalize_block1_opts({:router, router})

      true ->
        {:error, {:missing_option, :handler}}
    end
  end

  defp endpoint_opts(opts, handler) do
    opts
    |> Keyword.put(:handler, handler)
    |> Keyword.delete(:router)
    |> Keyword.delete(:context)
  end

  defp normalize_block1_opts(opts, handler_type) do
    if Keyword.has_key?(opts, :block1) do
      with :ok <- ensure_no_raw_block1_conflict(opts),
           {:ok, policy} <- Block1.new(Keyword.fetch!(opts, :block1)),
           :ok <- ensure_supported_block1_mode(policy, handler_type) do
        endpoint_opts =
          opts
          |> Keyword.delete(:block1)
          |> Keyword.merge(Block1.to_connection_opts(policy))

        {:ok, endpoint_opts}
      else
        {:error, reason} -> {:error, {:invalid_block1, reason}}
      end
    else
      {:ok, opts}
    end
  end

  defp ensure_supported_block1_mode(%Block1{mode: :streaming}, {:router, router}) do
    if Router.supports_block1_streaming?(router) do
      :ok
    else
      {:error, :streaming_requires_block1_callback}
    end
  end

  defp ensure_supported_block1_mode(%Block1{}, _handler_type) do
    :ok
  end

  defp ensure_no_raw_block1_conflict(opts) do
    raw_keys = [:block1_max_body_size, :block1_mode, :block1_preferred_block_size]

    if Enum.any?(raw_keys, &Keyword.has_key?(opts, &1)) do
      {:error, :conflicting_options}
    else
      :ok
    end
  end

  defp resolve_endpoint(server) when is_pid(server) do
    {:ok, server}
  end

  defp resolve_endpoint(server) do
    case GenServer.whereis(server) do
      nil -> {:error, {:endpoint_unavailable, server}}
      endpoint -> {:ok, endpoint}
    end
  end
end
