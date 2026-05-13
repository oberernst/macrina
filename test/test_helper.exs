case :net_kernel.start(:"macrina_test@127.0.0.1", %{name_domain: :longnames}) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
  {:error, reason} -> IO.warn("ERL distribution unavailable (#{inspect(reason)}); cluster tests will be skipped")
end

ExUnit.start(exclude: [:cluster])
