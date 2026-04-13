defmodule Macrina.Observe.Subscription do
  @moduledoc """
  Client-side observe subscription handle.

  Returned by `Macrina.Client.observe/3` and passed to
  `Macrina.Client.cancel_observe/1`. Also delivered inside
  `{:macrina_observe, subscription, response}` notification messages
  so the receiver can pattern-match on subscriptions.
  """

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
