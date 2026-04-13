defmodule Macrina.Resource do
  @moduledoc """
  Routable CoAP resource with pattern-matched paths and content negotiation.

  Resources define a path pattern, optional method handlers (as static
  responses or builder functions), and optional discovery attributes. Used
  with `Macrina.Router.dispatch/3` for data-driven request routing.

  ## Path patterns

    * `"/temperature"` — literal path segments
    * `"/devices/:device_id"` — named parameter capture
    * `"/files/*path"` — terminal glob capture (matches all remaining segments)

  ## Content negotiation

  Method handlers can be a single action or a keyword list of
  content-format-keyed representations. When multiple representations
  exist, the resource negotiates using the request's `Accept` option.
  """

  alias Macrina.{ContentFormat, Request, Response}
  alias Macrina.Discovery.Resource, as: DiscoveryResource

  @method_keys [:get, :post, :put, :delete]

  @type path_segment :: String.t() | {:param, atom()} | {:glob, atom()}
  @type representation_key :: :default | atom() | non_neg_integer()
  @type path_param_value :: String.t() | [String.t()]
  @type path_params :: %{optional(atom()) => path_param_value()}
  @type response_builder :: (Request.t(), map() -> Response.t() | nil)
  @type action :: {:response, Response.t()} | {:builder, response_builder()}
  @type representations :: {:representations, [{representation_key(), action()}]}
  @type t :: %__MODULE__{
          path: [path_segment()],
          discovery_path: nil | [String.t()],
          handlers: %{atom() => action() | representations()},
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

  def match?(%__MODULE__{} = resource, %Request{} = request) do
    not is_nil(action_for_method(resource, request.method)) and
      params(resource, request) != :error
  end

  def match?(_resource, _request) do
    false
  end

  def call(%__MODULE__{handlers: handlers} = resource, %Request{} = request, context)
      when is_map(context) do
    with {:ok, action} <- Map.fetch(handlers, request.method),
         {:ok, path_params} <- params(resource, request) do
      route_context = put_path_params(context, path_params)
      execute_action(action, request, route_context)
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
    cond do
      Keyword.get(opts, :discoverable) == false ->
        {:ok, nil}

      Keyword.has_key?(opts, :discovery_path) ->
        normalize_concrete_path(Keyword.fetch!(opts, :discovery_path))

      concrete_path?(path) ->
        {:ok, path}

      true ->
        {:error, :dynamic_resource_requires_discovery_path}
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
    case Keyword.take(opts, @method_keys) do
      [] ->
        {:error, :missing_handler}

      method_opts ->
        Enum.reduce_while(method_opts, {:ok, %{}}, fn {method, action}, {:ok, handlers} ->
          case normalize_method_action(action) do
            {:ok, normalized_action} ->
              next_handlers = Map.put(handlers, method, normalized_action)
              {:cont, {:ok, next_handlers}}

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
          next_representations = [
            {normalized_format, normalized_action} | normalized_representations
          ]

          {:cont, {:ok, next_representations}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      representation, _acc ->
        {:halt, {:error, {:invalid_representation, representation}}}
    end)
    |> case do
      {:ok, normalized_representations} ->
        ordered_representations = Enum.reverse(normalized_representations)
        {:ok, {:representations, ordered_representations}}

      {:error, reason} ->
        {:error, reason}
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

  defp action_for_method(%__MODULE__{handlers: handlers}, method) do
    Map.get(handlers, method)
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

  defp normalize_concrete_path(path) do
    case DiscoveryResource.new(path, []) do
      {:ok, %DiscoveryResource{path: normalized_path}} -> {:ok, normalized_path}
      {:error, reason} -> {:error, reason}
    end
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
            next_segments = [normalized_segment | segments]
            {:cont, {:ok, next_segments}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case normalized_path do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_segments(path) when is_list(path) do
    Enum.reduce_while(path, {:ok, []}, fn segment, {:ok, segments} ->
      case normalize_segment(segment) do
        {:ok, normalized_segment} ->
          next_segments = [normalized_segment | segments]
          {:cont, {:ok, next_segments}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, reason} -> {:error, reason}
    end
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
