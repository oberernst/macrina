defmodule Macrina.IncidentTest do
  alias Macrina.{Incident, Incident.Note}

  use ExUnit.Case

  setup do
    note = %Note{id: Macrina.id(), timestamp: DateTime.utc_now()}
    incident = Incident.new(Macrina.id(), Macrina.id())
    [incident: incident, note: note]
  end

  test "add_note/2", %{incident: incident, note: note} do
    assert %Incident{notes: [^note]} = Incident.add_note(incident, note)
  end

  test "close/2", %{incident: incident, note: note} do
    assert %Incident{notes: [^note], open?: false} = Incident.close(incident, note)
  end

  test "new/2" do
    [group_id, id] = Enum.map(1..2, fn _ -> Macrina.id() end)

    assert %Incident{group_id: ^group_id, id: ^id, notes: [], open?: true} =
             Incident.new(group_id, id)
  end
end
