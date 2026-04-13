defmodule Macrina.Message.Opts.Block do
  @moduledoc """
  Block option value (RFC 7959).

  Represents the decoded `Block1` or `Block2` option with its block number,
  more-blocks flag, and negotiated block size.
  """

  @type t :: %__MODULE__{number: integer(), more: boolean(), size: integer()}
  defstruct [:number, :more, :size]
end
