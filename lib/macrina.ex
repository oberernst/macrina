defmodule Macrina do
  defp append_port(ip_string, port), do: "#{ip_string}/#{port}"

  def conn_name({_, _, _, _} = ip, port) do
    ip |> Tuple.to_list() |> Enum.join(".") |> append_port(port)
  end

  def conn_name({_, _, _, _, _, _, _, _} = ip, port) do
    ip |> Tuple.to_list() |> Enum.join(":") |> append_port(port)
  end
end
