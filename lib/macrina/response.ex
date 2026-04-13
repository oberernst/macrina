defmodule Macrina.Response do
  alias Macrina.Message

  defstruct [:code, :control_block, :descriptive_block, :id, :options, :payload, :token, :type]

  @type t :: %__MODULE__{
          code: atom(),
          control_block: term(),
          descriptive_block: term(),
          id: non_neg_integer(),
          options: [{String.t(), term()}],
          payload: binary(),
          token: binary(),
          type: :ack | :con | :non | :res
        }

  def new(code, opts \\ []) when is_atom(code) and is_list(opts) do
    %__MODULE__{
      code: code,
      control_block: Keyword.get(opts, :control_block),
      descriptive_block: Keyword.get(opts, :descriptive_block),
      id: Keyword.get(opts, :id),
      options: Keyword.get(opts, :options, []),
      payload: Keyword.get(opts, :payload, <<>>),
      token: Keyword.get(opts, :token, <<>>),
      type: Keyword.get(opts, :type, :ack)
    }
  end

  def from_message(%Message{} = message) do
    %__MODULE__{
      code: message.code,
      control_block: message.control_block,
      descriptive_block: message.descriptive_block,
      id: message.id,
      options: message.options,
      payload: message.payload,
      token: message.token,
      type: message.type
    }
  end
end
