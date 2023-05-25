defmodule Macrina.Codes do
  @method_codes ~w(empty get post put delete)a
  @response_codes ~w(created deleted valid changed content bad_request unauthorized bad_option forbidden not_found method_not_allowed not_acceptable precondition_failed request_entity_too_large unsupported_content_format internal_server_error not_implemented bad_gateway service_unavailable gateway_timeout  proxying_not_supported)a

  def method_codes, do: @method_codes
  def response_codes, do: @response_codes

  # Method Codes
  def parse(0, 0), do: :empty
  def parse(0, 1), do: :get
  def parse(0, 2), do: :post
  def parse(0, 3), do: :put
  def parse(0, 4), do: :delete

  # Response Codes
  def parse(2, 1), do: :created
  def parse(2, 2), do: :deleted
  def parse(2, 3), do: :valid
  def parse(2, 31), do: :continue
  def parse(2, 4), do: :changed
  def parse(2, 5), do: :content
  def parse(4, 0), do: :bad_request
  def parse(4, 1), do: :unauthorized
  def parse(4, 2), do: :bad_option
  def parse(4, 3), do: :forbidden
  def parse(4, 4), do: :not_found
  def parse(4, 5), do: :method_not_allowed
  def parse(4, 6), do: :not_acceptable
  def parse(4, 8), do: :request_entity_incomplete
  def parse(4, 12), do: :precondition_failed
  def parse(4, 13), do: :request_entity_too_large
  def parse(4, 15), do: :unsupported_content_format
  def parse(5, 0), do: :internal_server_error
  def parse(5, 1), do: :not_implemented
  def parse(5, 2), do: :bad_gateway
  def parse(5, 3), do: :service_unavailable
  def parse(5, 4), do: :gateway_timeout
  def parse(5, 5), do: :proxying_not_supported

  def parse(c, dd), do: raise("unassigned code: #{c}, #{dd}")

  # Method Codes
  def parse(:empty), do: {0, 0}
  def parse(:get), do: {0, 1}
  def parse(:post), do: {0, 2}
  def parse(:put), do: {0, 3}
  def parse(:delete), do: {0, 4}

  # Response Codes

  def parse(:created), do: {2, 1}
  def parse(:deleted), do: {2, 2}
  def parse(:valid), do: {2, 3}
  def parse(:continue), do: {2, 31}
  def parse(:changed), do: {2, 4}
  def parse(:content), do: {2, 5}
  def parse(:bad_request), do: {4, 0}
  def parse(:unauthorized), do: {4, 1}
  def parse(:bad_option), do: {4, 2}
  def parse(:forbidden), do: {4, 3}
  def parse(:not_found), do: {4, 4}
  def parse(:method_not_allowed), do: {4, 5}
  def parse(:not_acceptable), do: {4, 6}
  def parse(:precondition_failed), do: {4, 12}
  def parse(:request_entity_too_large), do: {4, 13}
  def parse(:unsupported_content_format), do: {4, 15}
  def parse(:internal_server_error), do: {5, 0}
  def parse(:not_implemented), do: {5, 1}
  def parse(:bad_gateway), do: {5, 2}
  def parse(:service_unavailable), do: {5, 3}
  def parse(:gateway_timeout), do: {5, 4}
  def parse(:proxying_not_supported), do: {5, 5}

  def parse(code), do: raise("unassigned code: #{code}")
end
