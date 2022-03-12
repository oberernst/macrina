defmodule Macrina.CoAP.Connection do
  use GenServer

  defstruct [:ip4, :ip6, :port, :token]

  @type t :: %__MODULE__{
          ip4: :inets.ip4_address(),
          ip6: :inets.ip6_address(),
          port: integer(),
          token: binary()
        }

  def start_link(args) do
    port = Keyword.fetch!(args, :port)
    token = Keyword.fetch!(args, :token)

    case Keyword.fetch!(args, :ip) do
      {_, _, _, _} = ip ->
        GenServer.start_link(__MODULE__, %__MODULE__{ip4: ip, port: port, token: token})

      {_, _, _, _, _, _, _, _} = ip ->
        GenServer.start_link(__MODULE__, %__MODULE__{ip6: ip, port: port, token: token})
    end
  end

  def init(state) do
    {:ok, state}
  end
end
