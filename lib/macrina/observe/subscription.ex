defmodule Macrina.Observe.Subscription do
  alias Macrina.Request

  @enforce_keys [:connection, :notify_to, :path, :request, :token]
  defstruct [:connection, :notify_to, :path, :request, :token]

  @type t :: %__MODULE__{
          connection: pid(),
          notify_to: pid(),
          path: [String.t()],
          request: Request.t(),
          token: binary()
        }
end
