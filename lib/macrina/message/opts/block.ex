defmodule Macrina.Message.Opts.Block do
  @type t :: %__MODULE__{number: integer(), more: boolean(), size: integer()}
  defstruct [:number, :more, :size]
end
