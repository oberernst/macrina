defmodule Macrina.Handler do
  require Logger
  alias Macrina.{Connection, Message}

  @doc """
  Macrina requires two Handler.call/2 implentations:
  - one for handling valid CoAP messages
  - one for handling other UDP packets
  """
  @callback call(Connection.t(), Message.t()) :: :ok | {:error, [any()]}
  @callback call(Connection.t(), binary()) :: :ok | {:error, [any()]}
end
