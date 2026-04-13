defmodule Macrina.Server do
  alias Macrina.Endpoint

  def start_link(opts) when is_list(opts) do
    Endpoint.start_link(opts)
  end
end
