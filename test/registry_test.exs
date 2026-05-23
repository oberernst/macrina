defmodule Macrina.RegistryTest do
  use ExUnit.Case, async: true

  alias Macrina.Registry, as: MR

  describe "via/2,3" do
    test "wraps a name-only key in the standard :via tuple" do
      assert MR.via(:my_endpoint) ==
               {:via, Registry, {Macrina.Registry, :my_endpoint}}
    end

    test "wraps a {name, role} key when a role is given" do
      assert MR.via(:my_endpoint, :listener) ==
               {:via, Registry, {Macrina.Registry, {:my_endpoint, :listener}}}
    end

    test "accepts a compound role value" do
      key = {:session, {{127, 0, 0, 1}, 5683}}

      assert MR.via(:my_endpoint, key) ==
               {:via, Registry, {Macrina.Registry, {:my_endpoint, key}}}
    end
  end

  describe "whereis/2" do
    test "returns nil when no process is registered under the key" do
      assert MR.whereis(:nonexistent_endpoint, :listener) == nil
    end

    test "returns the pid of a process registered through Registry" do
      name = {:macrina_registry_test_endpoint, System.unique_integer([:positive])}

      task =
        Task.async(fn ->
          {:ok, _} = Registry.register(Macrina.Registry, {name, :listener}, nil)
          receive do: (:stop -> :ok)
        end)

      Process.sleep(20)

      pid = MR.whereis(name, :listener)
      assert pid == task.pid

      send(task.pid, :stop)
      Task.await(task)
    end
  end

  describe "lookup/2" do
    test "returns {pid, value} for a registered process" do
      name = {:macrina_registry_lookup_test, System.unique_integer([:positive])}
      tag = :a_tag

      task =
        Task.async(fn ->
          {:ok, _} = Registry.register(Macrina.Registry, {name, :listener}, tag)
          receive do: (:stop -> :ok)
        end)

      Process.sleep(20)

      assert {pid, ^tag} = MR.lookup(name, :listener)
      assert pid == task.pid

      send(task.pid, :stop)
      Task.await(task)
    end

    test "returns nil when no process is registered" do
      assert MR.lookup(:nonexistent_endpoint, :listener) == nil
    end
  end
end
