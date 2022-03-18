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
    Logger.info("#{port} sending ack #{Base.encode64(ack)}")
    Logger.info("#{port} echoing con #{Base.encode64(echo)}")
    {:ok, [ack, echo]}
  end

  def call(%Connection{port: port}, %Message{} = message) do
    echo = Message.encode(message)
    Logger.info("#{port} echoing non #{Base.encode64(echo)}")
    {:ok, [echo]}
  end
end
