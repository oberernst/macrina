defmodule Macrina.Router do
  @moduledoc """
  Behaviour and utilities for CoAP request routers.

  A router module implements `call/2` to handle requests, and optionally
  `block1/2` for streaming uploads and `discover/2` for `/.well-known/core`
  resource listing.

  For data-driven routing, combine `Macrina.Resource` definitions with
  `dispatch/3` and `discovery_resources/1` to derive both request handling
  and discovery from a single resource list.
  """

  alias Macrina.{Block1.Chunk, Request, Resource, Response}
  alias Macrina.Discovery.Resource, as: DiscoveryResource

  @callback call(Request.t(), map()) :: Response.t() | nil
  @callback block1(Chunk.t(), map()) :: Response.t() | nil
  @callback discover(Request.t(), map()) :: [DiscoveryResource.t()] | nil

  @optional_callbacks block1: 2, discover: 2

  @doc """
  Dispatches a request against a list of `Macrina.Resource` definitions.

  Returns the matched resource's response, or a `:not_found` response
  (configurable via the `:not_found` option).
  """
  def dispatch(resources, %Request{} = request, context, opts \\ [])
      when is_list(resources) and is_map(context) and is_list(opts) do
    not_found = Keyword.get(opts, :not_found, Response.new(:not_found))

    case Enum.find(resources, &Resource.match?(&1, request)) do
      %Resource{} = resource -> Resource.call(resource, request, context)
      nil -> not_found
    end
  end

  @doc """
  Converts a list of `Macrina.Resource` structs into their
  `Macrina.Discovery.Resource` equivalents for `/.well-known/core`.
  """
  def discovery_resources(resources) when is_list(resources) do
    Enum.reduce_while(resources, {:ok, []}, fn
      %Resource{} = resource, {:ok, discovery_resources} ->
        case Resource.discovery_resource(resource) do
          :skip ->
            {:cont, {:ok, discovery_resources}}

          {:ok, %DiscoveryResource{} = discovery_resource} ->
            next_resources = [discovery_resource | discovery_resources]
            {:cont, {:ok, next_resources}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      resource, _acc ->
        {:halt, {:error, {:invalid_resource, resource}}}
    end)
    |> case do
      {:ok, discovery_resources} -> {:ok, Enum.reverse(discovery_resources)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Like `discovery_resources/1` but raises on failure."
  def discovery_resources!(resources) when is_list(resources) do
    case discovery_resources(resources) do
      {:ok, discovery_resources} -> discovery_resources
      {:error, reason} -> raise ArgumentError, "invalid router resources: #{inspect(reason)}"
    end
  end

  @doc "Returns `true` if the router module exports `block1/2`."
  def supports_block1_streaming?(router) when is_atom(router) do
    function_exported?(router, :block1, 2)
  end

  @doc "Returns `true` if the router module exports `discover/2`."
  def supports_discovery?(router) when is_atom(router) do
    function_exported?(router, :discover, 2)
  end
end
