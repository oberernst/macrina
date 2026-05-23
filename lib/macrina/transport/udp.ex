defmodule Macrina.Transport.UDP do
  @moduledoc false

  @behaviour Macrina.Transport

  @impl true
  def open(opts) do
    port = Keyword.get(opts, :port, 0)
    active = Keyword.get(opts, :active, true)
    extra = Keyword.get(opts, :inet_opts, [])

    :gen_udp.open(port, [:binary, {:active, active}, {:reuseaddr, true} | extra])
  end

  @impl true
  def send(socket, {ip, port}, packet) when is_binary(packet) do
    :gen_udp.send(socket, {ip, port}, packet)
  end

  @impl true
  def close(socket) do
    :gen_udp.close(socket)
    :ok
  end
end
