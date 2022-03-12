defmodule Macrina.Incident.Teams.URLs do
  alias Macrina.{Incident, Incident.Sink}

  def patch(%Incident{
        sink: %Sink{channel_id: channel_id, group_id: group_id, thread_id: thread_id}
      }) do
    "/teams/#{group_id}/channels/#{channel_id}/messages/#{thread_id}"
  end

  def post(%Incident{sink: %Sink{channel_id: channel_id, group_id: group_id, thread_id: nil}}) do
    "/teams/#{group_id}/channels/#{channel_id}/messages"
  end

  def post(%Incident{
        sink: %Sink{channel_id: channel_id, group_id: group_id, thread_id: thread_id}
      }) do
    "/teams/#{group_id}/channels/#{channel_id}/messages/#{thread_id}/replies"
  end
end
