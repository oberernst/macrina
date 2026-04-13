defmodule Macrina.Router do
  alias Macrina.{Request, Response}

  @callback call(Request.t(), map()) :: Response.t() | nil
end
