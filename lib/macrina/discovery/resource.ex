defmodule Macrina.Discovery.Resource do
  @enforce_keys [:path]
  defstruct [:path, attributes: []]

  @type attribute_scalar :: String.t() | atom() | non_neg_integer()
  @type attribute_value :: true | attribute_scalar() | [attribute_scalar()]
  @type t :: %__MODULE__{
          path: [String.t()],
          attributes: [{String.t(), attribute_value()}]
        }

  def new(path, attributes \\ []) do
    with {:ok, normalized_path} <- normalize_path(path),
         {:ok, normalized_attributes} <- normalize_attributes(attributes) do
      {:ok, %__MODULE__{path: normalized_path, attributes: normalized_attributes}}
    end
  end

  def new!(path, attributes \\ []) do
    case new(path, attributes) do
      {:ok, resource} -> resource
      {:error, reason} -> raise ArgumentError, "invalid discovery resource: #{inspect(reason)}"
    end
  end

  defp normalize_path(path) when is_binary(path) do
    trimmed_path = String.trim_leading(path, "/")

    normalized_path =
      case trimmed_path do
        "" -> []
        _path -> String.split(trimmed_path, "/", trim: false)
      end

    {:ok, normalized_path}
  end

  defp normalize_path(path) when is_list(path) do
    if Enum.all?(path, &is_binary/1) do
      {:ok, path}
    else
      {:error, {:invalid_path, path}}
    end
  end

  defp normalize_path(path) do
    {:error, {:invalid_path, path}}
  end

  defp normalize_attributes(attributes) when is_list(attributes) do
    Enum.reduce_while(attributes, {:ok, []}, fn
      {name, value}, {:ok, normalized_attributes} ->
        case normalize_attribute(name, value) do
          {:ok, normalized_attribute} ->
            next_attributes = [normalized_attribute | normalized_attributes]
            {:cont, {:ok, next_attributes}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      attribute, _acc ->
        {:halt, {:error, {:invalid_attribute, attribute}}}
    end)
    |> case do
      {:ok, normalized_attributes} -> {:ok, Enum.reverse(normalized_attributes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_attributes(attributes) do
    {:error, {:invalid_attributes, attributes}}
  end

  defp normalize_attribute(name, value) do
    with {:ok, normalized_name} <- normalize_attribute_name(name),
         {:ok, normalized_value} <- normalize_attribute_value(value) do
      {:ok, {normalized_name, normalized_value}}
    end
  end

  defp normalize_attribute_name(name) when is_atom(name) do
    {:ok, Atom.to_string(name)}
  end

  defp normalize_attribute_name(name) when is_binary(name) and byte_size(name) > 0 do
    {:ok, name}
  end

  defp normalize_attribute_name(name) do
    {:error, {:invalid_attribute_name, name}}
  end

  defp normalize_attribute_value(true) do
    {:ok, true}
  end

  defp normalize_attribute_value(value) when is_binary(value) do
    {:ok, value}
  end

  defp normalize_attribute_value(value) when is_atom(value) do
    {:ok, Atom.to_string(value)}
  end

  defp normalize_attribute_value(value) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp normalize_attribute_value(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized_values} ->
      case normalize_attribute_list_value(value) do
        {:ok, normalized_value} ->
          next_values = [normalized_value | normalized_values]
          {:cont, {:ok, next_values}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized_values} -> {:ok, Enum.reverse(normalized_values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_attribute_value(value) do
    {:error, {:invalid_attribute_value, value}}
  end

  defp normalize_attribute_list_value(value) when is_binary(value) do
    {:ok, value}
  end

  defp normalize_attribute_list_value(value) when is_atom(value) do
    {:ok, Atom.to_string(value)}
  end

  defp normalize_attribute_list_value(value) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp normalize_attribute_list_value(value) do
    {:error, {:invalid_attribute_value, value}}
  end
end
