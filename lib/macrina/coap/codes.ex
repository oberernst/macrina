defmodule Macrina.CoAP.Codes do
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
  def parse(2, 4), do: :changed
  def parse(2, 5), do: :content
  def parse(4, 0), do: :bad_request
  def parse(4, 1), do: :unauthorized
  def parse(4, 2), do: :bad_option
  def parse(4, 3), do: :forbidden
  def parse(4, 4), do: :not_found
  def parse(4, 5), do: :method_not_allowed
  def parse(4, 6), do: :not_acceptable
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
end
