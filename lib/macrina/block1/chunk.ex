defmodule Macrina.Block1.Chunk do
  @moduledoc """
  A single streamed `Block1` upload chunk delivered to a handler.

  The underlying `message` preserves the request method, URI options, token, and
  current payload chunk. `bytes` tracks the total accepted upload size so far.
  """

  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  @enforce_keys [:block, :bytes, :complete, :message]
  defstruct [:block, :bytes, :complete, :content_format, :message]

  @type t :: %__MODULE__{
          block: Block.t(),
          bytes: non_neg_integer(),
          complete: boolean(),
          content_format: term() | nil,
          message: Message.t()
        }

  def from_message(%Message{descriptive_block: %Block{} = block} = message, transfer)
      when is_map(transfer) do
    %__MODULE__{
      block: block,
      bytes: Map.fetch!(transfer, :bytes),
      complete: not block.more,
      content_format: Map.get(transfer, :content_format),
      message: message
    }
  end
end
