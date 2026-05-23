defmodule Macrina.ObserveTest do
  use ExUnit.Case, async: false

  alias Macrina.{Client, Endpoint, Observe, Request, Response, Server}

  defmodule ClientEndpointRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context), do: nil
  end

  defmodule ObserveRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context) do
      Response.new(:content, payload: "initial")
    end
  end

  def telemetry_handler(event, measurements, metadata, pid) do
    send(pid, {event, measurements, metadata})
  end

  defp stop_process(pid) when is_pid(pid) do
    Process.exit(pid, :normal)
    :ok
  end

  describe "subscribe/3, notifications/2, cancel/3" do
    test "sequences notifications and cancels subscriptions" do
      endpoint = spawn(fn -> receive do: (:stop -> :ok) end)
      token = <<1, 2, 3, 4>>

      subscriber =
        Task.async(fn ->
          assert {:ok, 0} = Observe.subscribe(endpoint, "/sensors/temp", token)

          send(self(), :ready)
          receive do: (:done -> :ok)
        end)

      :ok = Task.yield(subscriber, 50) |> handle_yield_ready()

      assert {:ok, [%{observe: 1, path: ["sensors", "temp"], token: ^token, connection: pid}]} =
               Observe.notifications(endpoint, "/sensors/temp")

      assert pid == subscriber.pid

      assert {:ok, [%{observe: 2, path: ["sensors", "temp"], token: ^token}]} =
               Observe.notifications(endpoint, ["sensors", "temp"])

      send(subscriber.pid, :done)
      Task.await(subscriber)
      send(endpoint, :stop)
    end

    test "auto-evicts entries when the subscriber process dies" do
      endpoint = spawn(fn -> receive do: (:stop -> :ok) end)
      token = <<9, 9, 9, 9>>

      subscriber =
        spawn(fn ->
          {:ok, 0} = Observe.subscribe(endpoint, "/auto-evict", token)
          send(self(), :registered)
          Process.sleep(:infinity)
        end)

      Process.sleep(20)
      assert {:ok, [%{token: ^token}]} = Observe.notifications(endpoint, "/auto-evict")

      Process.exit(subscriber, :kill)
      Process.sleep(20)

      assert {:ok, []} = Observe.notifications(endpoint, "/auto-evict")
      send(endpoint, :stop)
    end

    test "cancel/3 removes only the matching token for the calling process" do
      endpoint = spawn(fn -> receive do: (:stop -> :ok) end)

      subscriber =
        Task.async(fn ->
          {:ok, 0} = Observe.subscribe(endpoint, "/multi", <<1>>)
          {:ok, 0} = Observe.subscribe(endpoint, "/multi", <<2>>)
          :ok = Observe.cancel(endpoint, "/multi", <<1>>)

          send(self(), :ready)
          receive do: (:done -> :ok)
        end)

      Process.sleep(20)

      assert {:ok, [%{token: <<2>>}]} = Observe.notifications(endpoint, "/multi")

      send(subscriber.pid, :done)
      Task.await(subscriber)
      send(endpoint, :stop)
    end
  end

  describe "two endpoints in one VM" do
    test "do not see each other's subscriptions" do
      ep_a = spawn(fn -> receive do: (:stop -> :ok) end)
      ep_b = spawn(fn -> receive do: (:stop -> :ok) end)

      sub_a =
        Task.async(fn ->
          {:ok, 0} = Observe.subscribe(ep_a, "/shared", <<0xAA>>)
          send(self(), :ready)
          receive do: (:done -> :ok)
        end)

      sub_b =
        Task.async(fn ->
          {:ok, 0} = Observe.subscribe(ep_b, "/shared", <<0xBB>>)
          send(self(), :ready)
          receive do: (:done -> :ok)
        end)

      Process.sleep(20)

      assert {:ok, [%{token: <<0xAA>>}]} = Observe.notifications(ep_a, "/shared")
      assert {:ok, [%{token: <<0xBB>>}]} = Observe.notifications(ep_b, "/shared")

      send(sub_a.pid, :done)
      send(sub_b.pid, :done)
      Task.await(sub_a)
      Task.await(sub_b)
      send(ep_a, :stop)
      send(ep_b, :stop)
    end
  end

  test "client observe receives notifications, emits telemetry, and cancels" do
    handler_id = "observe-public-api-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:macrina, :observe, :register],
          [:macrina, :observe, :notify],
          [:macrina, :observe, :cancel]
        ],
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, server} = Server.start_link(router: ObserveRouter, port: 0)
    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)

    endpoint_name = {:global, {:observe_test_endpoint, make_ref()}}

    {:ok, endpoint} =
      Endpoint.start_link(router: ClientEndpointRouter, port: 0, name: endpoint_name)

    {:ok, endpoint_socket} = Endpoint.socket(endpoint_name)

    on_exit(fn ->
      stop_process(endpoint)
      :gen_udp.close(endpoint_socket)
      stop_process(server)
    end)

    assert {:ok, client} =
             Client.new(ip: {127, 0, 0, 1}, port: server_port, endpoint: endpoint_name)

    request = Request.from_uri!(:get, "/temperature")

    assert {:ok, subscription, response} = Client.observe(client, request, notify_to: self())
    assert response.payload == "initial"
    assert Response.observe(response) == 0
    assert subscription.path == ["temperature"]

    assert {:ok, count} =
             Server.notify(
               server,
               "/temperature",
               Response.new(:content, payload: "23.1 C")
             )

    assert count == 1

    assert_receive {:macrina_observe, ^subscription, notification}, 1_000
    assert notification.payload == "23.1 C"
    assert Response.observe(notification) == 1
  end

  defp handle_yield_ready({:ok, _}), do: :ok
  defp handle_yield_ready(_), do: :ok
end
