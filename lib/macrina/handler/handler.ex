defmodule Macrina.Handler do
  require Logger
  alias Macrina.{Connection, Message}

  @callback call(Connection.t(), Message.t()) :: {:ok, [binary()]} | {:error, term()}
end
