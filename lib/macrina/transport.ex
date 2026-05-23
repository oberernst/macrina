defmodule Macrina.Transport do
  @moduledoc false

  # Behaviour for Macrina endpoints' wire transports. The 1.0 release
  # ships only `Macrina.Transport.UDP`; the seam exists so DTLS and
  # CoAP-over-TCP can land in a later release without churning the
  # `Macrina.Endpoint` / `Macrina.Peer.Session` shells.
  #
  # An open transport in `:active` mode delivers received datagrams to
  # the controlling process as `{:udp, socket, ip, port, packet}`
  # messages. `Macrina.Endpoint`'s UDP listener relies on that contract;
  # alternate transports must mimic the shape.

  @type opts :: keyword()
  @type socket :: term()
  @type peer :: {:inet.ip_address(), :inet.port_number()}
  @type packet :: binary()

  @callback open(opts()) :: {:ok, socket()} | {:error, term()}
  @callback send(socket(), peer(), packet()) :: :ok | {:error, term()}
  @callback close(socket()) :: :ok
end
