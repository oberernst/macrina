defmodule Macrina.Transport do
  @moduledoc false

  # Behaviour for wire transports. The 1.0 release ships only
  # `Macrina.Transport.UDP`.
  #
  # An open `:active` transport delivers datagrams to the controlling process
  # as `{:udp, socket, ip, port, packet}`. `Macrina.Endpoint` relies on that
  # shape from every transport.

  @type opts :: keyword()
  @type socket :: term()
  @type peer :: {:inet.ip_address(), :inet.port_number()}
  @type packet :: binary()

  @callback open(opts()) :: {:ok, socket()} | {:error, term()}
  @callback send(socket(), peer(), packet()) :: :ok | {:error, term()}
  @callback close(socket()) :: :ok
end
