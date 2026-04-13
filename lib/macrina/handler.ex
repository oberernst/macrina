defmodule Macrina.Handler do
  alias Macrina.{Connection, Message}

  @callback call(Connection.t(), Message.t() | binary()) :: Message.t() | nil
end
