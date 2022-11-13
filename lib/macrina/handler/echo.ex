defmodule Macrina.Handler.Echo do
  @behaviour Macrina.Handler
  require Logger
  alias Macrina.{Connection, Message}

  @impl true
  def call(%Connection{}, %Message{type: type}) when type in [:ack, :res] do
    :ok
  end

  def call(%Connection{ip: ip, port: port, socket: socket}, %Message{type: :con} = message) do
    ack = Message.encode(%Message{message | type: :ack})
    echo = Message.encode(message)
    Logger.debug("#{port} sending ack #{Base.encode64(ack)}")
    Logger.debug("#{port} echoing con #{Base.encode64(echo)}")

    [ack, echo]
    |> Enum.map(&:gen_udp.send(socket, {ip, port}, &1))
    |> Enum.split_with(&elem(&1, 0))
    |> case do
      {_good, [] = _bad} -> :ok
      {_good, bad} -> {:error, Enum.map(bad, &elem(&1, 1))}
    end
  end

  def call(%Connection{ip: ip, port: port, socket: socket}, %Message{} = message) do
    echo = Message.encode(message)
    Logger.debug("#{port} echoing non #{Base.encode64(echo)}")

    case :gen_udp.send(socket, {ip, port}, echo) do
      :ok -> :ok
      {:error, reason} -> {:error, [reason]}
    end
  end
end
