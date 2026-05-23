defmodule Macrina.Observe.Registry do
  @moduledoc false

  def child_spec(_arg) do
    [keys: :duplicate, name: __MODULE__]
    |> Registry.child_spec()
    |> Supervisor.child_spec(id: __MODULE__)
  end
end
