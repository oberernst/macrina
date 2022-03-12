defmodule Macrina.Response do
  alias Macrina.Request

  @doc """
  Build an empty ACK response to a given `Macrina.Request`

  Examples:

      iex> req = %Macrina.Request{
      iex>    code: :empty,
      iex>    message_id: 1,
      iex>    options: [],
      iex>    payload: <<>>,
      iex>    token: <<32, 119, 204, 99>>,
      iex>    type: :confirmable
      iex>  }
      iex> res = Macrina.Response.ack(req)
      iex> Macrina.Request.decode(res)
      {:ok, %Macrina.Request{
        code: :empty,
        message_id: 2,
        options: [],
        payload: <<>>,
        token: <<32, 119, 204, 99>>,
        type: :acknowledgement
      }}

  """
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
