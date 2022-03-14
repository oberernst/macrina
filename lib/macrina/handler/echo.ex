defmodule Macrina.Handler.Echo do
  @behaviour Macrina.Handler
  require Logger
  alias Macrina.{Connection, Message}

  @impl true
  def call(%Connection{}, %Message{type: type}) when type in [:ack, :res] do
    {:ok, []}
  end

  def call(%Connection{port: port}, %Message{type: :con} = message) do
    ack = Message.encode(%Message{message | type: :ack})
    echo = Message.encode(message)
    Logger.info("#{port} sending ack #{:binary.encode_hex(ack)}")
    Logger.info("#{port} echoing con #{:binary.encode_hex(echo)}")
    {:ok, [ack, echo]}
  end

  def call(%Connection{port: port}, %Message{} = message) do
    echo = Message.encode(message)
    Logger.info("#{port} echoing non #{:binary.encode_hex(echo)}")
    {:ok, [echo]}
  end
end
