defmodule Macrina.Discovery do
  alias Macrina.{Request, Response}
  alias Macrina.Discovery.Resource

  @well_known_core_path [".well-known", "core"]

  def well_known_core_path do
    @well_known_core_path
  end

  def discovery_request?(%Request{method: :get, path: @well_known_core_path}) do
    true
  end

  def discovery_request?(%Request{}) do
    false
  end

  def encode(resources) when is_list(resources) do
    resources
    |> Enum.reduce_while({:ok, []}, fn resource, {:ok, encoded_resources} ->
      case encode_resource_entry(resource) do
        {:ok, encoded_resource} ->
          next_resources = [encoded_resource | encoded_resources]
          {:cont, {:ok, next_resources}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, encoded_resources} ->
        payload = encoded_resources |> Enum.reverse() |> Enum.join(",")
        {:ok, payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def response(resources, request \\ nil) when is_list(resources) do
    with :ok <- ensure_acceptable_content_format(request),
         {:ok, payload} <- encode(resources) do
      {:ok,
       Response.new(:content,
         payload: payload,
         content_format: :application_link_format
       )}
    else
      {:error, :not_acceptable} -> {:ok, Response.new(:not_acceptable)}
    end
  end

  def response!(resources, request \\ nil) when is_list(resources) do
    case response(resources, request) do
      {:ok, response} -> response
      {:error, reason} -> raise ArgumentError, "invalid discovery resources: #{inspect(reason)}"
    end
  end

  defp ensure_acceptable_content_format(nil) do
    :ok
  end

  defp ensure_acceptable_content_format(%Request{} = request) do
    case Request.accept(request) do
      nil -> :ok
      :application_link_format -> :ok
      40 -> :ok
      _other -> {:error, :not_acceptable}
    end
  end

  defp encode_resource_entry(%Resource{} = resource) do
    {:ok, encode_resource(resource)}
  end

  defp encode_resource_entry(resource) do
    {:error, {:invalid_resource, resource}}
  end

  defp encode_resource(%Resource{path: path, attributes: attributes}) do
    encoded_attributes = Enum.map_join(attributes, "", &encode_attribute/1)
    "<#{encode_path(path)}>" <> encoded_attributes
  end

  defp encode_path([]) do
    "/"
  end

  defp encode_path(path) do
    encoded_segments = Enum.map_join(path, "/", &URI.encode/1)
    "/" <> encoded_segments
  end

  defp encode_attribute({name, true}) do
    ";#{name}"
  end

  defp encode_attribute({name, value}) when is_integer(value) do
    ";#{name}=#{value}"
  end

  defp encode_attribute({name, value}) when is_binary(value) do
    ";#{name}=\"#{escape_attribute_value(value)}\""
  end

  defp encode_attribute({name, values}) when is_list(values) do
    encoded_values = Enum.map_join(values, " ", &attribute_list_value/1)
    ";#{name}=\"#{escape_attribute_value(encoded_values)}\""
  end

  defp attribute_list_value(value) when is_binary(value) do
    value
  end

  defp attribute_list_value(value) when is_atom(value) do
    Atom.to_string(value)
  end

  defp attribute_list_value(value) when is_integer(value) do
    Integer.to_string(value)
  end

  defp escape_attribute_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
