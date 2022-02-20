defmodule Macrina.Incident do
  alias __MODULE__
  defstruct group_id: nil, id: nil, notes: [], open?: true

  @type t :: %Incident{
          group_id: String.t(),
          id: String.t(),
          notes: [Note.t()],
          open?: boolean()
        }

  defmodule Note do
    defstruct id: nil, timestamp: nil
    @type t :: %Note{id: String.t(), timestamp: DateTime.t()}
  end

  @spec add_note(t(), Note.t()) :: t()
  def add_note(%Incident{notes: notes} = incident, %Note{} = note) do
    %Incident{incident | notes: [note | notes]}
  end

  @spec close(t(), Note.t()) :: t()
  def close(%Incident{notes: notes} = incident, %Note{} = note) do
    %Incident{incident | notes: [note | notes], open?: false}
  end

  @spec new(group_id :: String.t(), id :: String.t()) :: t()
  def new(group_id, id) do
    %Incident{group_id: group_id, id: id}
  end
end
