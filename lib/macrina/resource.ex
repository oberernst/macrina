defmodule Macrina.Resource do
  alias Macrina.{ContentFormat, Request, Response}
  alias Macrina.Discovery.Resource, as: DiscoveryResource

  @method_keys [:get, :post, :put, :delete]

  @type path_segment :: String.t() | {:param, atom()} | {:glob, atom()}
  @type response_builder :: Response.t() | (Request.t(), map() -> Response.t() | nil)
  @type representation_key :: :default | atom() | non_neg_integer()
  @type t :: %__MODULE__{
          path: [path_segment()],
          discovery_path: nil | [String.t()],
          handlers: %{atom() => term()},
          attributes: [{String.t(), term()}]
        }

  defstruct [:path, :discovery_path, :handlers, attributes: []]

  def new(path, opts \\ []) when is_list(opts) do
    with {:ok, normalized_path} <- normalize_path(path),
         {:ok, discovery_path} <- normalize_discovery_path(normalized_path, opts),
         {:ok, normalized_attributes} <- normalize_attributes(normalized_path, opts),
         {:ok, normalized_handlers} <- normalize_handlers(opts) do
      {:ok,
       %__MODULE__{
         path: normalized_path,
         discovery_path: discovery_path,
         handlers: normalized_handlers,
         attributes: normalized_attributes
       }}
    end
  end

  def new!(path, opts \\ []) when is_list(opts) do
    case new(path, opts) do
      {:ok, resource} -> resource
      {:error, reason} -> raise ArgumentError, "invalid router resource: #{inspect(reason)}"
    end
  end

  def match?(%__MODULE__{path: path, handlers: handlers}, %Request{method: method, path: path}) do
    Map.has_key?(handlers, method)
  end

  def match?(%__MODULE__{path: path, handlers: handlers}, %Request{
        method: method,
        path: request_path
      }) do
    Map.has_key?(handlers, method) and match_path(path, request_path) != :error
  end

  def match?(%__MODULE__{}, %Request{}) do
    false
  end

  def match?(_resource, _request) do
    false
  end

  def call(%__MODULE__{handlers: handlers} = resource, %Request{} = request, context)
      when is_map(context) do
    with {:ok, action} <- Map.fetch(handlers, request.method),
         {:ok, path_params} <- params(resource, request) do
      action
      |> execute_action(request, put_path_params(context, path_params))
    else
      :error -> Response.new(:not_found)
    end
  end

  def params(%__MODULE__{path: path}, %Request{path: request_path}) do
    match_path(path, request_path)
  end

  def params(%__MODULE__{}, %Request{}) do
    :error
  end

  def discovery_resource(%__MODULE__{discovery_path: nil}) do
    :skip
  end

  def discovery_resource(%__MODULE__{discovery_path: path, attributes: attributes}) do
    DiscoveryResource.new(path, attributes)
  end

  defp normalize_path(path) do
    case path_segments(path) do
      {:ok, segments} -> validate_path_segments(segments)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_path_segments(segments) do
    if valid_glob_position?(segments) do
      {:ok, segments}
    else
      {:error, :glob_must_be_terminal}
    end
  end

  defp normalize_discovery_path(path, opts) do
    case Keyword.fetch(opts, :discoverable) do
      {:ok, false} ->
        {:ok, nil}

      _other ->
        case Keyword.fetch(opts, :discovery_path) do
          {:ok, discovery_path} ->
            case DiscoveryResource.new(discovery_path, []) do
              {:ok, %DiscoveryResource{path: normalized_path}} -> {:ok, normalized_path}
              {:error, reason} -> {:error, reason}
            end

          :error ->
            if concrete_path?(path) do
              {:ok, path}
            else
              {:error, :dynamic_resource_requires_discovery_path}
            end
        end
    end
  end

  defp normalize_attributes(path, opts) do
    attributes = Keyword.get(opts, :attributes, [])

    discovery_path = Keyword.get(opts, :discovery_path, concrete_path(path))

    case DiscoveryResource.new(discovery_path, attributes) do
      {:ok, %DiscoveryResource{attributes: normalized_attributes}} -> {:ok, normalized_attributes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_handlers(opts) do
    method_opts = Keyword.take(opts, @method_keys)

    if method_opts == [] do
      {:error, :missing_handler}
    else
      Enum.reduce_while(method_opts, {:ok, %{}}, fn {method, action}, {:ok, handlers} ->
        case normalize_method_action(action) do
          {:ok, normalized_action} ->
            {:cont, {:ok, Map.put(handlers, method, normalized_action)}}

          {:error, reason} ->
            {:halt, {:error, {method, reason}}}
        end
      end)
    end
  end

  defp normalize_method_action(%Response{} = response) do
    {:ok, {:response, response}}
  end

  defp normalize_method_action(builder) when is_function(builder, 2) do
    {:ok, {:builder, builder}}
  end

  defp normalize_method_action(representations) when is_list(representations) do
    normalize_representations(representations)
  end

  defp normalize_method_action(action) do
    {:error, {:invalid_action, action}}
  end

  defp normalize_representations([]) do
    {:error, :missing_representation}
  end

  defp normalize_representations(representations) do
    Enum.reduce_while(representations, {:ok, []}, fn
      {format, action}, {:ok, normalized_representations} ->
        with {:ok, normalized_format} <- normalize_representation_format(format),
             {:ok, normalized_action} <- normalize_representation_action(action) do
          {:cont, {:ok, normalized_representations ++ [{normalized_format, normalized_action}]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      representation, _acc ->
        {:halt, {:error, {:invalid_representation, representation}}}
    end)
    |> case do
      {:ok, normalized_representations} -> {:ok, {:representations, normalized_representations}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_representation_format(:default) do
    {:ok, :default}
  end

  defp normalize_representation_format(format) do
    case ContentFormat.encode(format) do
      {:ok, encoded_format} -> {:ok, encoded_format}
      :error -> {:error, {:invalid_content_format, format}}
    end
  end

  defp normalize_representation_action(%Response{} = response) do
    {:ok, {:response, response}}
  end

  defp normalize_representation_action(builder) when is_function(builder, 2) do
    {:ok, {:builder, builder}}
  end

  defp normalize_representation_action(action) do
    {:error, {:invalid_action, action}}
  end

  defp execute_action({:response, %Response{} = response}, _request, _context) do
    response
  end

  defp execute_action({:builder, builder}, %Request{} = request, context) do
    builder.(request, context)
  end

  defp execute_action({:representations, representations}, %Request{} = request, context) do
    case select_representation(representations, request) do
      {:ok, {format, action}} ->
        action
        |> execute_action(request, context)
        |> maybe_put_content_format(format)

      :error ->
        Response.new(:not_acceptable)
    end
  end

  defp select_representation(representations, %Request{} = request) do
    case Request.accept(request) do
      nil ->
        case Enum.find(representations, fn {format, _action} -> format == :default end) do
          nil ->
            case representations do
              [representation | _rest] -> {:ok, representation}
              [] -> :error
            end

          representation ->
            {:ok, representation}
        end

      accept ->
        encoded_accept = normalize_accept(accept)

        case Enum.find(representations, fn {format, _action} -> format == encoded_accept end) do
          nil -> :error
          representation -> {:ok, representation}
        end
    end
  end

  defp normalize_accept(accept) do
    case ContentFormat.encode(accept) do
      {:ok, encoded_accept} -> encoded_accept
      :error -> accept
    end
  end

  defp maybe_put_content_format(nil, _format) do
    nil
  end

  defp maybe_put_content_format(%Response{} = response, :default) do
    response
  end

  defp maybe_put_content_format(%Response{} = response, format) do
    Response.put_content_format(response, format)
  end

  defp path_segments(path) when is_binary(path) do
    normalized_path =
      path
      |> String.trim_leading("/")
      |> case do
        "" -> []
        trimmed_path -> String.split(trimmed_path, "/", trim: false)
      end
      |> Enum.reduce_while({:ok, []}, fn segment, {:ok, segments} ->
        case normalize_segment(segment) do
          {:ok, normalized_segment} ->
            {:cont, {:ok, segments ++ [normalized_segment]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    normalized_path
  end

  defp path_segments(path) when is_list(path) do
    Enum.reduce_while(path, {:ok, []}, fn segment, {:ok, segments} ->
      case normalize_segment(segment) do
        {:ok, normalized_segment} ->
          {:cont, {:ok, segments ++ [normalized_segment]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp path_segments(path) do
    {:error, {:invalid_path, path}}
  end

  defp normalize_segment(":" <> name) when byte_size(name) > 0 do
    {:ok, {:param, String.to_atom(name)}}
  end

  defp normalize_segment("*" <> name) when byte_size(name) > 0 do
    {:ok, {:glob, String.to_atom(name)}}
  end

  defp normalize_segment(segment) when is_binary(segment) do
    {:ok, segment}
  end

  defp normalize_segment({:param, name}) when is_atom(name) do
    {:ok, {:param, name}}
  end

  defp normalize_segment({:glob, name}) when is_atom(name) do
    {:ok, {:glob, name}}
  end

  defp normalize_segment(segment) do
    {:error, {:invalid_path_segment, segment}}
  end

  defp match_path([], []) do
    {:ok, %{}}
  end

  defp match_path([{:glob, name}], request_path) do
    {:ok, %{name => request_path}}
  end

  defp match_path([segment | remaining_path], [segment | remaining_request_path]) do
    match_path(remaining_path, remaining_request_path)
  end

  defp match_path([{:param, name} | remaining_path], [value | remaining_request_path]) do
    with {:ok, params} <- match_path(remaining_path, remaining_request_path) do
      {:ok, Map.put(params, name, value)}
    end
  end

  defp match_path(_path, _request_path) do
    :error
  end

  defp valid_glob_position?(segments) do
    segments
    |> Enum.with_index()
    |> Enum.all?(fn
      {{:glob, _name}, index} -> index == length(segments) - 1
      {_segment, _index} -> true
    end)
  end

  defp put_path_params(context, path_params) when map_size(path_params) == 0 do
    context
  end

  defp put_path_params(context, path_params) do
    Map.put(context, :path_params, path_params)
  end

  defp concrete_path?(path) do
    Enum.all?(path, &is_binary/1)
  end

  defp concrete_path(path) do
    if concrete_path?(path) do
      path
    else
      []
    end
  end
end
