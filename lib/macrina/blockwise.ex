defmodule Macrina.Blockwise do
  @moduledoc false

  # Pure helpers for CoAP Block1/Block2 transfer state, keyed per logical
  # exchange so concurrent blockwise traffic on a single peer does not collide.

  alias Macrina.{Codes, Message, Message.Opts.Block}

  @block1_option "Block1"
  @block2_option "Block2"
  @content_format_option "Content-Format"
  @method_codes Codes.method_codes()

  @type transfer_key :: {:block1 | :block2, term()}

  @type transfer :: %{
          blocks: %{optional(non_neg_integer()) => binary()},
          bytes: non_neg_integer(),
          content_format: term() | nil,
          next_block: non_neg_integer(),
          size: pos_integer()
        }

  @type assembly_result ::
          {:ok, binary(),
           %{count: pos_integer(), first_block: non_neg_integer(), last_block: non_neg_integer()}}
          | {:error, :missing_block,
             %{missing_block: non_neg_integer(), received_blocks: non_neg_integer()}}
          | :error

  @spec put_transfer(%{optional(transfer_key()) => transfer()}, Message.t()) ::
          {:ok, %{optional(transfer_key()) => transfer()}} | {:error, atom()}
  def put_transfer(transfers, %Message{descriptive_block: %Block{} = block} = message)
      when is_map(transfers) do
    key = transfer_key(message)
    transfer = Map.get(transfers, key, new_transfer(message))

    with :ok <- validate_block_size(transfer, block),
         :ok <- validate_content_format(transfer, message),
         :ok <- validate_sequence(transfer, block, message.payload) do
      next_transfer = put_block(transfer, block, message.payload, message)
      {:ok, Map.put(transfers, key, next_transfer)}
    end
  end

  def put_transfer(_transfers, _message) do
    {:error, :missing_block}
  end

  @spec assemble(%{optional(transfer_key()) => transfer()}, Message.t()) :: assembly_result()
  def assemble(transfers, %Message{} = message) when is_map(transfers) do
    case Map.fetch(transfers, transfer_key(message)) do
      {:ok, %{blocks: blocks}} ->
        assemble_blocks(blocks)

      :error ->
        :error
    end
  end

  @spec delete_transfer(%{optional(transfer_key()) => transfer()}, Message.t()) ::
          %{optional(transfer_key()) => transfer()}
  def delete_transfer(transfers, %Message{} = message) when is_map(transfers) do
    Map.delete(transfers, transfer_key(message))
  end

  @spec transfer(%{optional(transfer_key()) => transfer()}, Message.t()) ::
          {:ok, transfer()} | :error
  def transfer(transfers, %Message{} = message) when is_map(transfers) do
    Map.fetch(transfers, transfer_key(message))
  end

  @spec transfer_key(Message.t()) :: transfer_key()
  def transfer_key(%Message{} = message) do
    {transfer_kind(message), transfer_identity(message)}
  end

  defp new_transfer(%Message{descriptive_block: %Block{size: size}} = message) do
    %{
      blocks: %{},
      bytes: 0,
      content_format: content_format(message),
      next_block: 0,
      size: size
    }
  end

  defp validate_block_size(%{size: size}, %Block{size: size}) do
    :ok
  end

  defp validate_block_size(_transfer, _block) do
    {:error, :block_size_mismatch}
  end

  defp validate_content_format(%{content_format: nil}, _message) do
    :ok
  end

  defp validate_content_format(%{content_format: content_format}, %Message{} = message) do
    case content_format(message) do
      nil -> :ok
      ^content_format -> :ok
      _other -> {:error, :content_format_mismatch}
    end
  end

  defp validate_sequence(
         %{blocks: blocks, next_block: next_block},
         %Block{number: number},
         payload
       ) do
    case Map.fetch(blocks, number) do
      {:ok, ^payload} ->
        :ok

      {:ok, _other_payload} ->
        {:error, :out_of_sequence}

      :error when number == next_block ->
        :ok

      :error ->
        {:error, :out_of_sequence}
    end
  end

  defp put_block(
         %{blocks: blocks, bytes: bytes} = transfer,
         %Block{number: number},
         payload,
         %Message{} = message
       ) do
    next_blocks = Map.put_new(blocks, number, payload)
    next_content_format = content_format(message) || transfer.content_format
    next_bytes = bytes + block_byte_delta(blocks, number, payload)

    %{
      transfer
      | blocks: next_blocks,
        bytes: next_bytes,
        content_format: next_content_format,
        next_block: max(transfer.next_block, number + 1)
    }
  end

  defp block_byte_delta(blocks, number, payload) do
    if Map.has_key?(blocks, number) do
      0
    else
      byte_size(payload)
    end
  end

  defp assemble_blocks(blocks) do
    sorted_blocks = Enum.sort_by(blocks, &elem(&1, 0), :asc)

    case contiguous_blocks(sorted_blocks) do
      :ok ->
        payload = Enum.reduce(sorted_blocks, <<>>, &append_block_payload/2)
        first_block = first_block(sorted_blocks)
        last_block = last_block(sorted_blocks)

        metadata = %{
          count: length(sorted_blocks),
          first_block: first_block,
          last_block: last_block
        }

        {:ok, payload, metadata}

      {:error, missing_block} ->
        metadata = %{missing_block: missing_block, received_blocks: length(sorted_blocks)}
        {:error, :missing_block, metadata}
    end
  end

  defp contiguous_blocks(sorted_blocks) do
    case Enum.reduce_while(sorted_blocks, {-1, true}, &contiguous_block_result/2) do
      {_last_block, true} -> :ok
      {missing_block, false} -> {:error, missing_block}
    end
  end

  defp contiguous_block_result({block_number, _payload}, {last_block, _valid?}) do
    if last_block + 1 == block_number do
      {:cont, {block_number, true}}
    else
      {:halt, {block_number - 1, false}}
    end
  end

  defp append_block_payload({_block_number, payload}, acc) do
    acc <> payload
  end

  defp first_block([{first, _payload} | _sorted]) do
    first
  end

  defp first_block([]) do
    nil
  end

  defp last_block([]) do
    nil
  end

  defp last_block(sorted) do
    {last, _payload} = List.last(sorted)
    last
  end

  defp content_format(%Message{options: options}) do
    normalized_options = options || []

    case Enum.find(normalized_options, fn {name, _value} -> name == @content_format_option end) do
      {@content_format_option, value} -> value
      nil -> nil
    end
  end

  defp transfer_kind(%Message{code: code}) when code in @method_codes do
    :block1
  end

  defp transfer_kind(%Message{}) do
    :block2
  end

  # RFC 9175 §3.2: a server uses Request-Tag (if present) as the body
  # correlation key, with Token as the fallback. Same Token + different
  # Request-Tag means two distinct upload bodies.
  defp transfer_identity(%Message{} = message) do
    case request_tag(message) do
      {:ok, tag} -> {:request_tag, transfer_kind(message), tag}
      :error -> token_or_request_identity(message)
    end
  end

  defp token_or_request_identity(%Message{token: token} = message) when byte_size(token) > 0 do
    {:token, transfer_kind(message), token}
  end

  defp token_or_request_identity(%Message{} = message) do
    options =
      (message.options || [])
      |> Enum.reject(fn {name, _value} ->
        name in [@block1_option, @block2_option]
      end)

    {:request, message.code, options}
  end

  defp request_tag(%Message{options: nil}), do: :error

  defp request_tag(%Message{options: options}) do
    case List.keyfind(options, "Request-Tag", 0) do
      {"Request-Tag", tag} when is_binary(tag) -> {:ok, tag}
      _ -> :error
    end
  end
end
