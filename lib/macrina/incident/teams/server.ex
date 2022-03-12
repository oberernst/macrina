defmodule Macrina.Incident.Teams.Server do
  alias Macrina.{Incident, Incident.Sink}

  use GenServer

  def start_link(%Incident{id: id} = incident) do
    name = {:via, Registry, {IncidentRegistry, id}}
    GenServer.start_link(__MODULE__, incident, name: name)
  end

  def init(incident) do
    {:ok, nil, {:continue, incident}}
  end

  def handle_continue(%Incident{sink: %Sink{thread_id: nil}} = incident, nil) do
    # initial API call
    {:noreply, incident}
  end

  def handle_continue(incident, nil) do
    # fire requests for any notes that without acknowledgements
    {:noreply, incident}
  end
end
