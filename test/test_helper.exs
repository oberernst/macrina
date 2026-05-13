case :net_kernel.start(:"macrina_test@127.0.0.1", %{name_domain: :longnames}) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start()
