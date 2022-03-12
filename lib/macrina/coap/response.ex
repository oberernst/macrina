defmodule Macrina.CoAP.Response do
  alias Macrina.CoAP.Request

  def ack(%Request{message_id: id, token: token}) do
    message_id = id + 1

    <<
      1::unsigned-size(2),
      2::unsigned-size(2),
      byte_size(token)::unsigned-size(4),
      0::unsigned-size(3),
      0::unsigned-size(5),
      message_id::unsigned-size(16),
      token::binary,
      0::size(0)
    >>
  end
end
