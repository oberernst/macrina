defmodule Macrina.Incident do
  alias __MODULE__
  defstruct id: nil, notes: [], open?: true, sink: nil
  @type t :: %Incident{id: String.t(), notes: [Note.t()], open?: boolean(), sink: Sink.t()}

  defmodule Note do
    defstruct id: nil, timestamp: nil
    @type t :: %Note{id: String.t(), timestamp: DateTime.t()}

    @spec new(id :: String.t(), timestamp :: DateTime.t()) :: t()
    def new(id, timestamp) do
      %Note{id: id, timestamp: timestamp}
    end
  end

  defmodule Sink do
    alias Incident.Note
    defstruct channel_id: nil, drain: [], group_id: nil, thread_id: nil

    @type t :: %Sink{
            channel_id: String.t(),
            drain: [Note.t()],
            group_id: String.t(),
            thread_id: String.t() | nil
          }

    @spec new(channel_id :: String.t(), group_id :: String.t(), thread_id :: String.t()) :: t()
    def new(channel_id, group_id, thread_id) do
      %Sink{channel_id: channel_id, group_id: group_id, thread_id: thread_id}
    end
  end

  @spec add_note(t(), Note.t()) :: t()
  def add_note(%Incident{notes: notes} = incident, %Note{} = note) do
    %Incident{incident | notes: [note | notes]}
  end

  @spec close(t(), Note.t()) :: t()
  def close(%Incident{notes: notes} = incident, %Note{} = note) do
    %Incident{incident | notes: [note | notes], open?: false}
  end

  @spec new(id :: String.t(), sink :: Sink.t()) :: t()
  def new(id, sink) do
    %Incident{id: id, sink: sink}
  end
end
