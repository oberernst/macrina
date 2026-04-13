defmodule Macrina.Response do
  alias Macrina.{Codes, Message}

  defstruct [:code, :control_block, :descriptive_block, :id, :options, :payload, :token, :type]

  @type t :: %__MODULE__{
          code: atom(),
          control_block: term(),
          descriptive_block: term(),
          id: non_neg_integer(),
          options: [{String.t(), term()}],
          payload: binary(),
          token: binary(),
          type: :ack | :con | :non | :rst
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

  def to_message(%__MODULE__{} = response, %Message{} = request_message) do
    if Codes.valid_code?(response.code) do
      message =
        Message.response(request_message,
          code: response.code,
          options: response.options,
          payload: response.payload,
          type: response.type
        )

      {:ok, message}
    else
      {:error, {:invalid_response, {:unsupported_code, response.code}}}
    end
  end

  def to_message(%__MODULE__{} = response, nil) do
    if Codes.valid_code?(response.code) do
      message =
        Message.build(response.code,
          id: response.id,
          options: response.options,
          payload: response.payload,
          token: response.token,
          type: response.type
        )

      {:ok, message}
    else
      {:error, {:invalid_response, {:unsupported_code, response.code}}}
    end
  end

  def to_message!(%__MODULE__{} = response, request_message \\ nil) do
    case to_message(response, request_message) do
      {:ok, message} -> message
      {:error, reason} -> raise ArgumentError, "invalid CoAP response: #{inspect(reason)}"
    end
  end
end
