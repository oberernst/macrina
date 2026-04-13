defmodule Macrina.ContentFormat do
  @moduledoc """
  Content-Format codec (RFC 7252, Section 12.3).

  Maps between human-readable atoms (`:text_plain`, `:application_json`, etc.)
  and their integer wire values. Unknown integer values pass through unchanged
  for forward compatibility with newer IANA registry entries.
  """
  @formats_by_name %{
    text_plain: 0,
    application_link_format: 40,
    application_xml: 41,
    application_octet_stream: 42,
    application_exi: 47,
    application_json: 50,
    application_cbor: 60
  }
  @formats_by_number Map.new(@formats_by_name, fn {name, number} -> {number, name} end)

  def encode(name) when is_atom(name) do
    Map.fetch(@formats_by_name, name)
  end

  def encode(number) when is_integer(number) and number >= 0 do
    {:ok, number}
  end

  def encode(_value) do
    :error
  end

  def decode(number) when is_integer(number) and number >= 0 do
    case Map.fetch(@formats_by_number, number) do
      {:ok, name} -> {:ok, name}
      :error -> {:ok, number}
    end
  end

  def decode(_value) do
    :error
  end
end
