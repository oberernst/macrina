defmodule Macrina.Codes do
  @moduledoc """
  Bidirectional codec for CoAP method and response codes.

  Maps between atoms (`:get`, `:content`, `:not_found`, etc.) and their
  binary `{class, detail}` tuples as defined in RFC 7252, Section 12.1.
  """
  @method_codes ~w(empty get post put delete)a
  @response_codes ~w(request_entity_incomplete created deleted valid continue changed content bad_request unauthorized bad_option forbidden not_found method_not_allowed not_acceptable precondition_failed request_entity_too_large unsupported_content_format internal_server_error not_implemented bad_gateway service_unavailable gateway_timeout  proxying_not_supported)a
  @codes_by_number %{
    {0, 0} => :empty,
    {0, 1} => :get,
    {0, 2} => :post,
    {0, 3} => :put,
    {0, 4} => :delete,
    {2, 1} => :created,
    {2, 2} => :deleted,
    {2, 3} => :valid,
    {2, 31} => :continue,
    {2, 4} => :changed,
    {2, 5} => :content,
    {4, 0} => :bad_request,
    {4, 1} => :unauthorized,
    {4, 2} => :bad_option,
    {4, 3} => :forbidden,
    {4, 4} => :not_found,
    {4, 5} => :method_not_allowed,
    {4, 6} => :not_acceptable,
    {4, 8} => :request_entity_incomplete,
    {4, 12} => :precondition_failed,
    {4, 13} => :request_entity_too_large,
    {4, 15} => :unsupported_content_format,
    {5, 0} => :internal_server_error,
    {5, 1} => :not_implemented,
    {5, 2} => :bad_gateway,
    {5, 3} => :service_unavailable,
    {5, 4} => :gateway_timeout,
    {5, 5} => :proxying_not_supported
  }
  @numbers_by_code Map.new(@codes_by_number, fn {number, code} -> {code, number} end)

  def method_codes, do: @method_codes
  def response_codes, do: @response_codes
  def valid_code?(code) when is_atom(code), do: Map.has_key?(@numbers_by_code, code)
  def valid_code?(_code), do: false

  @spec decode(integer(), integer()) :: {:ok, atom()} | :error
  def decode(c, dd) do
    Map.fetch(@codes_by_number, {c, dd})
  end

  @spec encode(atom()) :: {:ok, {integer(), integer()}} | :error
  def encode(code) when is_atom(code) do
    Map.fetch(@numbers_by_code, code)
  end

  # Method Codes
  @spec parse(integer(), integer()) :: atom()
  def parse(c, dd) do
    case decode(c, dd) do
      {:ok, code} -> code
      :error -> raise("unassigned code: #{c}, #{dd}")
    end
  end

  # Method Codes
  @spec parse(atom()) :: {integer(), integer()}
  def parse(code) do
    case encode(code) do
      {:ok, parts} -> parts
      :error -> raise("unassigned code: #{code}")
    end
  end
end
