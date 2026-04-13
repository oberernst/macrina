defmodule Macrina.Server do
  alias Macrina.Endpoint

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

  defp build_endpoint_opts(opts) do
    handler = Keyword.get(opts, :handler)
    router = Keyword.get(opts, :router)
    context = Keyword.get(opts, :context, %{})

    cond do
      handler ->
        endpoint_opts = endpoint_opts(opts, handler)
        {:ok, endpoint_opts}

      router ->
        router_handler = {:router, router, context}
        endpoint_opts = endpoint_opts(opts, router_handler)
        {:ok, endpoint_opts}

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
end
