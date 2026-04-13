defmodule Macrina.Router do
  alias Macrina.{Block1.Chunk, Request, Response}

  @callback call(Request.t(), map()) :: Response.t() | nil
  @callback block1(Chunk.t(), map()) :: Response.t() | nil

  @optional_callbacks block1: 2

  def supports_block1_streaming?(router) when is_atom(router) do
    function_exported?(router, :block1, 2)
  end
end
