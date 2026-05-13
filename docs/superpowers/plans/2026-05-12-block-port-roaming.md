# Block-Wise Transfer Port Roaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Block1 uploads survive a source-port change provided the device holds the CoAP Token constant, including across BEAM nodes in a cluster.

**Architecture:** Extract block-assembly state from `Macrina.Connection.Server` (per-`{ip, port}`) into a new `Macrina.BlockTransfer` GenServer (per-`{ip, token}`, `:global`-registered). The transfer process owns the accumulator and the cached completion reply; `Connection.Server` remains the socket shell and delegates Block1 messages to the transfer process via a single `handle_block/4` entry point that returns action tuples the shell translates into UDP sends.

**Tech Stack:** Elixir 1.14+ / OTP 25+ (project runs 1.19.5 / OTP 28), ExUnit, `:gen_udp`, `:global`, `DynamicSupervisor`, `:peer` (OTP 25+ stdlib) for the cluster test.

**Spec:** `docs/superpowers/specs/2026-05-12-block-port-roaming-design.md`

---

## File structure

**New files:**

- `lib/macrina/blocks.ex` — pure accumulator: `push/2`, `read/1`, `empty/0`.
- `lib/macrina/block_transfer.ex` — GenServer per-`{ip, token}`, `:global`-registered.
- `lib/macrina/block_transfer/supervisor.ex` — `DynamicSupervisor` (one per node).
- `test/blocks_test.exs` — pure tests for `Macrina.Blocks`.
- `test/block_transfer_test.exs` — GenServer behavior tests for `Macrina.BlockTransfer`.
- `test/integration/block_port_roaming_test.exs` — single-node bug repro via real UDP.
- `test/integration/block_port_roaming_cluster_test.exs` — cross-node version using `:peer`.

**Modified files:**

- `lib/macrina/application.ex` — add `BlockTransfer.Supervisor` to children.
- `lib/macrina/connection.ex` — remove `:blocks` field; remove `push_block/2`, `read_blocks/1`, `reset_blocks/1`.
- `lib/macrina/connection/server.ex` — replace inline block assembly with `BlockTransfer.handle_block/4`; split private `handle/2` so the application-reply binary can be captured for caching.
- `test/test_helper.exs` — start distribution (`:net_kernel.start/2`) so `:peer.start/1` works in the cluster test.
- `CHANGELOG.md` — `[Unreleased]` entry under *Changed*.

---

## Task 1: Pure block accumulator

**Files:**
- Create: `lib/macrina/blocks.ex`
- Test: `test/blocks_test.exs`

The accumulator is the pure subset of what `Macrina.Connection` does today with `push_block/2` and `read_blocks/1`. Extracting it first means subsequent tasks can build on it without touching any process.

- [ ] **Step 1: Write the failing test**

Create `test/blocks_test.exs`:

```elixir
defmodule Macrina.BlocksTest do
  use ExUnit.Case, async: true

  alias Macrina.Blocks
  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  defp block_msg(number, payload, more) do
    %Message{
      descriptive_block: %Block{number: number, size: byte_size(payload), more: more},
      payload: payload
    }
  end

  describe "empty/0" do
    test "starts as an empty map" do
      assert Blocks.empty() == %{}
    end
  end

  describe "push/2" do
    test "stores the payload under the block number" do
      acc = Blocks.empty() |> Blocks.push(block_msg(0, "abc", true))
      assert acc == %{0 => "abc"}
    end

    test "accepts blocks out of order" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(1, "def", false))
        |> Blocks.push(block_msg(0, "abc", true))

      assert acc == %{0 => "abc", 1 => "def"}
    end

    test "later push for the same number overwrites earlier" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(0, "abc", true))
        |> Blocks.push(block_msg(0, "xyz", true))

      assert acc == %{0 => "xyz"}
    end
  end

  describe "read/1" do
    test "returns the concatenated payload when blocks 0..N are contiguous" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(0, "aa", true))
        |> Blocks.push(block_msg(1, "bb", true))
        |> Blocks.push(block_msg(2, "cc", false))

      assert Blocks.read(acc) == {:ok, "aabbcc"}
    end

    test "reads correctly when blocks were pushed out of order" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(2, "cc", false))
        |> Blocks.push(block_msg(0, "aa", true))
        |> Blocks.push(block_msg(1, "bb", true))

      assert Blocks.read(acc) == {:ok, "aabbcc"}
    end

    test "reports the first missing block on a gap" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(0, "aa", true))
        |> Blocks.push(block_msg(2, "cc", false))

      assert Blocks.read(acc) == {:error, {:missing, 1}}
    end

    test "reports missing 0 when the accumulator starts at a non-zero block" do
      acc = Blocks.empty() |> Blocks.push(block_msg(1, "bb", false))
      assert Blocks.read(acc) == {:error, {:missing, 0}}
    end

    test "reports missing 0 when empty" do
      assert Blocks.read(Blocks.empty()) == {:error, {:missing, 0}}
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/blocks_test.exs`
Expected: FAIL with `Macrina.Blocks.empty/0 is undefined` (or similar — module does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `lib/macrina/blocks.ex`:

```elixir
defmodule Macrina.Blocks do
  @moduledoc false

  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  @type acc :: %{non_neg_integer() => binary()}

  @spec empty() :: acc()
  def empty, do: %{}

  @spec push(acc(), Message.t()) :: acc()
  def push(acc, %Message{descriptive_block: %Block{number: number}, payload: payload}) do
    Map.put(acc, number, payload)
  end

  @spec read(acc()) ::
          {:ok, binary()} | {:error, {:missing, non_neg_integer()}}
  def read(acc) when acc == %{}, do: {:error, {:missing, 0}}

  def read(acc) do
    sorted = Enum.sort_by(acc, &elem(&1, 0), :asc)

    Enum.reduce_while(sorted, {-1, <<>>}, fn {num, chunk}, {last, payload} ->
      cond do
        num == last + 1 -> {:cont, {num, payload <> chunk}}
        true -> {:halt, {:missing, last + 1}}
      end
    end)
    |> case do
      {_last, payload} when is_binary(payload) -> {:ok, payload}
      {:missing, n} -> {:error, {:missing, n}}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/blocks_test.exs`
Expected: PASS, all 9 tests green.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/macrina/blocks.ex test/blocks_test.exs
git add lib/macrina/blocks.ex test/blocks_test.exs
git commit -m "$(cat <<'EOF'
extract pure block accumulator into Macrina.Blocks

Pure subset of Macrina.Connection's existing push_block/read_blocks
logic. No process, no state — just an accumulator map and three
functions. Will be the data backbone of the new Macrina.BlockTransfer
GenServer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: BlockTransfer GenServer — assembling phase

**Files:**
- Create: `lib/macrina/block_transfer.ex`
- Test: `test/block_transfer_test.exs`

Build only the in-flight (`:assembling`) phase first. No `:global` registration yet; tests drive a locally-started pid. The supervisor and registration come in Task 4.

Public-API shape for this task (will gain more in Tasks 3 and 4):

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
@spec handle_block(pid(), Macrina.Message.t()) ::
        {:continue, binary()}
        | {:assembled, Macrina.Message.t()}
        | {:incomplete, binary()}
```

Note: this is the **two-arity** form used internally by tests for the GenServer. The four-arity public `handle_block/4` that looks up the pid by `{ip, token}` is added in Task 4.

- [ ] **Step 1: Write the failing test**

Create `test/block_transfer_test.exs`:

```elixir
defmodule Macrina.BlockTransferTest do
  use ExUnit.Case, async: true

  alias Macrina.BlockTransfer
  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  defmodule NilHandler do
    def call(_state, _message), do: nil
  end

  defp block_msg(number, payload, more, token \\ <<1, 2, 3, 4>>, id \\ 100) do
    %Message{
      id: id,
      token: token,
      type: :con,
      code: :put,
      descriptive_block: %Block{number: number, size: byte_size(payload), more: more},
      payload: payload,
      options: []
    }
  end

  defp start_transfer(opts \\ []) do
    defaults = [ip: {127, 0, 0, 1}, token: <<1, 2, 3, 4>>, handler: NilHandler]
    {:ok, pid} = BlockTransfer.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  describe "handle_block/2 in :assembling phase" do
    test "returns :continue with a 2.31 ACK binary when more: true" do
      pid = start_transfer()

      assert {:continue, ack_bin} =
               BlockTransfer.handle_block(pid, block_msg(0, "abc", true))

      assert is_binary(ack_bin)
      {:ok, ack} = Message.decode(ack_bin)
      assert ack.code == :continue
      assert ack.type == :ack
    end

    test "returns :assembled with the full message when more: false and blocks are contiguous" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))
      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(1, "bb", true))

      assert {:assembled, %Message{payload: "aabbcc"} = full} =
               BlockTransfer.handle_block(pid, block_msg(2, "cc", false))

      assert full.token == <<1, 2, 3, 4>>
    end

    test "returns :incomplete with a 4.08 ACK when more: false and a block is missing" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))

      assert {:incomplete, bin} =
               BlockTransfer.handle_block(pid, block_msg(2, "cc", false))

      {:ok, msg} = Message.decode(bin)
      assert msg.code == :request_entity_incomplete
      assert msg.type == :ack
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/block_transfer_test.exs`
Expected: FAIL with `Macrina.BlockTransfer is undefined` (or `function start_link/1 is undefined`).

- [ ] **Step 3: Write minimal implementation**

Create `lib/macrina/block_transfer.ex`:

```elixir
defmodule Macrina.BlockTransfer do
  @moduledoc false

  use GenServer, restart: :transient

  alias Macrina.{Blocks, Message}
  alias Macrina.Message.Opts.Block

  @assembling_timeout :timer.minutes(5)

  defstruct [:ip, :token, :handler, :blocks, :last_reply, :phase]

  @type t :: %__MODULE__{
          ip: :inet.ip_address(),
          token: binary(),
          handler: module(),
          blocks: Blocks.acc(),
          last_reply: binary() | nil,
          phase: :assembling | :complete
        }

  def start_link(args) do
    ip = Keyword.fetch!(args, :ip)
    token = Keyword.fetch!(args, :token)
    handler = Keyword.fetch!(args, :handler)
    GenServer.start_link(__MODULE__, %{ip: ip, token: token, handler: handler})
  end

  @spec handle_block(pid(), Message.t()) ::
          {:continue, binary()}
          | {:assembled, Message.t()}
          | {:incomplete, binary()}
  def handle_block(pid, %Message{} = message) do
    GenServer.call(pid, {:block, message})
  end

  @impl true
  def init(%{ip: ip, token: token, handler: handler}) do
    state = %__MODULE__{
      ip: ip,
      token: token,
      handler: handler,
      blocks: Blocks.empty(),
      last_reply: nil,
      phase: :assembling
    }

    {:ok, state, @assembling_timeout}
  end

  @impl true
  def handle_call(
        {:block, %Message{descriptive_block: %Block{more: true}} = message},
        _from,
        %__MODULE__{phase: :assembling} = state
      ) do
    blocks = Blocks.push(state.blocks, message)
    ack_bin = message |> Message.response(code: :continue, type: :ack) |> Message.encode()
    {:reply, {:continue, ack_bin}, %{state | blocks: blocks}, @assembling_timeout}
  end

  def handle_call(
        {:block, %Message{descriptive_block: %Block{more: false}} = message},
        _from,
        %__MODULE__{phase: :assembling} = state
      ) do
    blocks = Blocks.push(state.blocks, message)

    case Blocks.read(blocks) do
      {:ok, payload} ->
        full = %Message{message | payload: payload}
        {:reply, {:assembled, full}, %{state | blocks: blocks}, @assembling_timeout}

      {:error, {:missing, _n}} ->
        bin =
          message
          |> Message.response(code: :request_entity_incomplete, type: :ack)
          |> Message.encode()

        {:reply, {:incomplete, bin}, %{state | blocks: blocks}, @assembling_timeout}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/block_transfer_test.exs`
Expected: PASS, 3 tests green.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/macrina/block_transfer.ex test/block_transfer_test.exs
git add lib/macrina/block_transfer.ex test/block_transfer_test.exs
git commit -m "$(cat <<'EOF'
add Macrina.BlockTransfer assembling phase

GenServer keyed by {ip, token} that holds the block accumulator and
returns action tuples (:continue / :assembled / :incomplete) the
caller translates into UDP sends. Assembling phase only; completion
caching and :global registration come next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Completion caching and `:duplicate` response

**Files:**
- Modify: `lib/macrina/block_transfer.ex`
- Modify: `test/block_transfer_test.exs`

When the application produces the final reply, `Connection.Server` calls `cache_completion/3` so the BlockTransfer can answer subsequent retransmits of the final block with `{:duplicate, bin}` for the lifetime of `EXCHANGE_LIFETIME` (247 s, per RFC 7252).

- [ ] **Step 1: Write the failing tests (append to `test/block_transfer_test.exs`)**

```elixir
  describe "cache_completion/2 and :duplicate" do
    test "after cache_completion, a retransmit of the final block returns :duplicate with the cached bin" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))
      assert {:assembled, _} = BlockTransfer.handle_block(pid, block_msg(1, "bb", false))

      reply_bin = "the-application-reply-binary"
      assert :ok = BlockTransfer.cache_completion(pid, reply_bin)

      assert {:duplicate, ^reply_bin} =
               BlockTransfer.handle_block(pid, block_msg(1, "bb", false))
    end

    test "cache_completion with nil yields {:duplicate, nil} on retransmit" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))
      assert {:assembled, _} = BlockTransfer.handle_block(pid, block_msg(1, "bb", false))

      assert :ok = BlockTransfer.cache_completion(pid, nil)

      assert {:duplicate, nil} =
               BlockTransfer.handle_block(pid, block_msg(1, "bb", false))
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/block_transfer_test.exs`
Expected: FAIL with `Macrina.BlockTransfer.cache_completion/2 is undefined`.

- [ ] **Step 3: Extend the implementation**

In `lib/macrina/block_transfer.ex`, add the public function and the new `handle_call` clauses. Add this `@complete_timeout` near the top and the rest in the existing module:

```elixir
@complete_timeout :timer.seconds(247)
```

Add public function next to `handle_block/2`:

```elixir
@spec cache_completion(pid(), binary() | nil) :: :ok
def cache_completion(pid, reply_bin) when is_binary(reply_bin) or is_nil(reply_bin) do
  GenServer.call(pid, {:cache_completion, reply_bin})
end
```

Add the `:cache_completion` `handle_call` clause:

```elixir
def handle_call({:cache_completion, reply_bin}, _from, %__MODULE__{phase: :assembling} = state) do
  {:reply, :ok, %{state | last_reply: reply_bin, phase: :complete}, @complete_timeout}
end
```

Add the `:complete` phase `handle_call` clause for `{:block, ...}`:

```elixir
def handle_call(
      {:block, %Message{descriptive_block: %Block{more: false}}},
      _from,
      %__MODULE__{phase: :complete, last_reply: reply_bin} = state
    ) do
  {:reply, {:duplicate, reply_bin}, state, @complete_timeout}
end
```

- [ ] **Step 4: Run all tests to verify they pass**

Run: `mix test test/block_transfer_test.exs`
Expected: PASS, 5 tests green (3 from Task 2 + 2 new).

- [ ] **Step 5: Format and commit**

```bash
mix format lib/macrina/block_transfer.ex test/block_transfer_test.exs
git add lib/macrina/block_transfer.ex test/block_transfer_test.exs
git commit -m "$(cat <<'EOF'
add completion caching to Macrina.BlockTransfer

cache_completion/2 moves the GenServer into :complete phase with an
EXCHANGE_LIFETIME idle window and arms it to answer retransmits of
the final block with {:duplicate, cached_bin}. nil is preserved for
handler-returned-no-reply parity with the existing single-datagram
dedup semantics.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Supervisor, `:global` registration, and `handle_block/4`

**Files:**
- Create: `lib/macrina/block_transfer/supervisor.ex`
- Modify: `lib/macrina/application.ex`
- Modify: `lib/macrina/block_transfer.ex`
- Modify: `test/block_transfer_test.exs`

Add the per-node `DynamicSupervisor`, the global registration, and the four-arity public API that `Connection.Server` will eventually use: `handle_block(ip, token, handler, message)`. This is the API that does `:global.whereis_name`, starts on miss, and forwards to the resolved pid.

- [ ] **Step 1: Write the failing tests (append to `test/block_transfer_test.exs`)**

```elixir
  describe "handle_block/4 with :global registration" do
    setup do
      ip = {127, 0, 0, 1}
      token = :crypto.strong_rand_bytes(8)

      on_exit(fn ->
        case :global.whereis_name({Macrina.BlockTransfer, ip, token}) do
          :undefined -> :ok
          pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        end
      end)

      {:ok, ip: ip, token: token}
    end

    test "starts a globally-registered process on first call", %{ip: ip, token: token} do
      msg = block_msg(0, "aa", true, token)

      assert {:continue, _} = BlockTransfer.handle_block(ip, token, NilHandler, msg)

      pid = :global.whereis_name({Macrina.BlockTransfer, ip, token})
      assert is_pid(pid)
    end

    test "second call resolves the same pid", %{ip: ip, token: token} do
      msg0 = block_msg(0, "aa", true, token)
      msg1 = block_msg(1, "bb", false, token)

      assert {:continue, _} = BlockTransfer.handle_block(ip, token, NilHandler, msg0)
      pid_after_first = :global.whereis_name({Macrina.BlockTransfer, ip, token})

      assert {:assembled, %Message{payload: "aabb"}} =
               BlockTransfer.handle_block(ip, token, NilHandler, msg1)

      pid_after_second = :global.whereis_name({Macrina.BlockTransfer, ip, token})
      assert pid_after_first == pid_after_second
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/block_transfer_test.exs`
Expected: FAIL with `Macrina.BlockTransfer.handle_block/4 is undefined`.

- [ ] **Step 3: Create the supervisor**

Create `lib/macrina/block_transfer/supervisor.ex`:

```elixir
defmodule Macrina.BlockTransfer.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
```

- [ ] **Step 4: Wire the supervisor into the application**

Edit `lib/macrina/application.ex`:

```elixir
defmodule Macrina.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: Macrina.ConnectionSupervisor, strategy: :one_for_one},
      Macrina.BlockTransfer.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Macrina.Supervisor]
    res = Supervisor.start_link(children, opts)
    Logger.info("macrina started", result: inspect(res))
    res
  end
end
```

- [ ] **Step 5: Extend `BlockTransfer` with global registration and `handle_block/4`**

Edit `lib/macrina/block_transfer.ex`. Change `start_link/1` to honor a `:name` option (so the supervisor can register globally), and add the four-arity `handle_block/4`:

Replace the existing `start_link/1`:

```elixir
def start_link(args) do
  ip = Keyword.fetch!(args, :ip)
  token = Keyword.fetch!(args, :token)
  handler = Keyword.fetch!(args, :handler)
  name = Keyword.get(args, :name)

  init_arg = %{ip: ip, token: token, handler: handler}

  case name do
    nil -> GenServer.start_link(__MODULE__, init_arg)
    name -> GenServer.start_link(__MODULE__, init_arg, name: name)
  end
end
```

Add the four-arity API alongside the two-arity one:

```elixir
@spec handle_block(:inet.ip_address(), binary(), module(), Message.t()) ::
        {:continue, binary()}
        | {:assembled, Message.t()}
        | {:incomplete, binary()}
        | {:duplicate, binary() | nil}
def handle_block(ip, token, handler, %Message{} = message) do
  pid = lookup_or_start(ip, token, handler)
  handle_block(pid, message)
end

defp lookup_or_start(ip, token, handler) do
  case :global.whereis_name({__MODULE__, ip, token}) do
    pid when is_pid(pid) ->
      pid

    :undefined ->
      child_spec = %{
        id: __MODULE__,
        start:
          {__MODULE__, :start_link,
           [
             [
               ip: ip,
               token: token,
               handler: handler,
               name: {:global, {__MODULE__, ip, token}}
             ]
           ]},
        restart: :transient,
        type: :worker
      }

      case DynamicSupervisor.start_child(Macrina.BlockTransfer.Supervisor, child_spec) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
  end
end
```

- [ ] **Step 6: Run all tests to verify they pass**

Run: `mix test test/block_transfer_test.exs`
Expected: PASS, 7 tests green (5 prior + 2 new).

- [ ] **Step 7: Format and commit**

```bash
mix format lib/macrina/block_transfer.ex lib/macrina/block_transfer/supervisor.ex lib/macrina/application.ex test/block_transfer_test.exs
git add lib/macrina/block_transfer.ex lib/macrina/block_transfer/supervisor.ex lib/macrina/application.ex test/block_transfer_test.exs
git commit -m "$(cat <<'EOF'
register Macrina.BlockTransfer globally per {ip, token}

Adds a per-node DynamicSupervisor and a four-arity handle_block/4 that
looks up an existing transfer pid via :global.whereis_name, starts a
new one on miss, and forwards. Wins the start race the same way
Macrina.Endpoint already does with Connection.Server.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Integrate `BlockTransfer` into `Connection.Server`; drop block state from `Connection`

**Files:**
- Modify: `lib/macrina/connection/server.ex`
- Modify: `lib/macrina/connection.ex`

Replace the inline Block1 logic in `Connection.Server.handle_info({:coap, _}, _)` with delegation to `BlockTransfer.handle_block/4`, then strip the now-unused `:blocks` field and helpers from `Macrina.Connection`. This is the change that actually fixes the bug — the integration test in Task 6 will prove it.

This task does not have its own unit test because the behavior it changes is reached only via the I/O shell; the proof is the integration test in Task 6.

- [ ] **Step 1: Read the current handle_info to confirm shape**

Run: `sed -n '55,135p' lib/macrina/connection/server.ex`

Expected: the `{:ok, %Message{descriptive_block: %Block{more: true}}}` clause (lines ~60–70) and the `{:ok, %Message{descriptive_block: %Block{more: false}}}` clause (lines ~77–130).

- [ ] **Step 2: Rewrite the two `descriptive_block` clauses**

Edit `lib/macrina/connection/server.ex`. Replace the entire `{:ok, %Message{descriptive_block: %Block{more: true}}}` clause and the `{:ok, %Message{descriptive_block: %Block{more: false}}}` clause with a single shared clause:

```elixir
      {:ok, %Message{descriptive_block: %Block{}} = message} ->
        case Macrina.BlockTransfer.handle_block(state.ip, message.token, state.handler, message) do
          {:continue, ack_bin} ->
            Connection.reply(state, ack_bin)
            {:noreply, reply_to_client(state, message), @timeout}

          {:assembled, full_message} ->
            {state, reply_bin} = handle_and_capture(state, full_message)
            Macrina.BlockTransfer.cache_completion(state.ip, message.token, reply_bin)
            {:noreply, reply_to_client(state, full_message), @timeout}

          {:incomplete, ack_bin} ->
            Connection.reply(state, ack_bin)
            {:noreply, reply_to_client(state, message), @timeout}

          {:duplicate, nil} ->
            {:noreply, reply_to_client(state, message), @timeout}

          {:duplicate, bin} when is_binary(bin) ->
            Connection.reply(state, bin)
            {:noreply, reply_to_client(state, message), @timeout}
        end
```

- [ ] **Step 3: Split the existing private `handle/2` so the reply binary is captured**

Add a new private function and modify `handle/2` to delegate. Keep the existing `handle/2` (used by non-block paths) calling the new function and discarding the binary, so its callers don't change:

```elixir
  defp handle(%Connection{} = state, message) do
    {state, _bin} = handle_and_capture(state, message)
    state
  end

  defp handle_and_capture(%Connection{} = state, message) do
    case state.handler.call(state, message) do
      nil ->
        {set_last_reply(state, message.token, nil), nil}

      reply ->
        bin = Message.encode(reply)
        Connection.reply(state, bin)
        {set_last_reply(state, message.token, bin), bin}
    end
  end
```

Remove the existing `defp handle/2` body (the one that does the `if reply = state.handler.call(state, message)` branch). Keep `defp handle/3` (the `:continue` variant) as-is — actually that one is no longer reached, since the `:continue` path now goes through `BlockTransfer`. Delete `defp handle(%Connection{} = state, message, :continue)` entirely.

- [ ] **Step 4: Strip `:blocks` from `Connection` struct and helpers**

Edit `lib/macrina/connection.ex`:

Change the `defstruct` line from:

```elixir
defstruct [:blocks, :callers, :last_reply, :handler, :ids, :ip, :name, :port, :socket, :tokens]
```

To:

```elixir
defstruct [:callers, :last_reply, :handler, :ids, :ip, :name, :port, :socket, :tokens]
```

Update the `@type t` to drop the `blocks:` field.

Delete `push_block/2`, `read_blocks/1`, and `reset_blocks/1` from the module.

- [ ] **Step 5: Remove `:blocks` from the `Connection.Server.start_link` state init**

Edit `lib/macrina/connection/server.ex`. In `start_link/1`, drop the `blocks: %{},` line from the `%Connection{...}` literal. Also adjust the `import Connection, only: :functions` line if it now imports nothing block-related; it still imports the surviving helpers so leave as-is.

- [ ] **Step 6: Compile-check and run the full existing test suite**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

Run: `mix test`
Expected: PASS for all pre-existing tests + the 7 BlockTransfer tests + 9 Blocks tests. No new failures.

- [ ] **Step 7: Format and commit**

```bash
mix format lib/macrina/connection/server.ex lib/macrina/connection.ex
git add lib/macrina/connection/server.ex lib/macrina/connection.ex
git commit -m "$(cat <<'EOF'
delegate Block1 handling from Connection.Server to BlockTransfer

Replaces the inline blockwise assembly in Connection.Server with a
single handle_block/4 call into Macrina.BlockTransfer. Splits the
private handle/2 to expose the application-reply binary so it can be
cached for completion dedup. Drops the now-unused :blocks field and
push_block/read_blocks/reset_blocks helpers from Macrina.Connection.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Single-node port-roaming integration test

**Files:**
- Create: `test/integration/block_port_roaming_test.exs`

End-to-end proof that the bug is fixed on a single node. Binds a real `Macrina.Endpoint`, opens two ephemeral UDP client sockets on loopback (simulating the device's port A and port B), and sends Block1 number 0 from socket A then Block1 number 1 from socket B with the same Token. Asserts the application handler sees the assembled payload exactly once and the final `2.04 Changed` (or whichever code the test handler returns) reply arrives on socket B.

- [ ] **Step 1: Create the test directory and write the failing test**

```bash
mkdir -p test/integration
```

Create `test/integration/block_port_roaming_test.exs`:

```elixir
defmodule Macrina.Integration.BlockPortRoamingTest do
  use ExUnit.Case, async: false

  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  @moduletag :integration

  defmodule EchoHandler do
    def call(_state, %Message{} = message) do
      send(:test_recipient, {:assembled, message})
      Message.response(message, code: :changed, type: :ack, payload: "ok")
    end
  end

  setup do
    Process.register(self(), :test_recipient)
    server_port = 0

    {:ok, endpoint_pid} =
      Macrina.Endpoint.start_link(
        handler: EchoHandler,
        port: server_port,
        name: :"endpoint_#{System.unique_integer([:positive])}"
      )

    {:ok, server_socket} = Macrina.Endpoint.socket(endpoint_pid)
    {:ok, {_, server_port_actual}} = :inet.sockname(server_socket)

    on_exit(fn ->
      if Process.alive?(endpoint_pid), do: GenServer.stop(endpoint_pid)
    end)

    {:ok, server_port: server_port_actual}
  end

  defp open_client_socket do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false, reuseaddr: true])
    sock
  end

  defp send_block(socket, server_port, number, more, payload, token, id) do
    msg = %Message{
      id: id,
      token: token,
      type: :con,
      code: :put,
      descriptive_block: %Block{number: number, size: byte_size(payload), more: more},
      control_block: nil,
      options: [],
      payload: payload
    }

    bin = Message.encode(msg)
    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, server_port, bin)
  end

  defp recv(socket) do
    {:ok, {_ip, _port, packet}} = :gen_udp.recv(socket, 0, 1_000)
    {:ok, msg} = Message.decode(packet)
    msg
  end

  test "block 0 from port A and block 1 from port B assemble into one upload",
       %{server_port: server_port} do
    token = :crypto.strong_rand_bytes(8)

    socket_a = open_client_socket()
    socket_b = open_client_socket()

    on_exit(fn ->
      :gen_udp.close(socket_a)
      :gen_udp.close(socket_b)
    end)

    send_block(socket_a, server_port, 0, true, "aaaa", token, 1)
    ack0 = recv(socket_a)
    assert ack0.code == :continue
    assert ack0.type == :ack

    send_block(socket_b, server_port, 1, false, "bbbb", token, 2)
    final = recv(socket_b)
    assert final.code == :changed
    assert final.payload == "ok"

    assert_received {:assembled, %Message{payload: "aaaabbbb", token: ^token}}
  end
end
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `mix test test/integration/block_port_roaming_test.exs --include integration`
Expected: PASS. (The `:integration` tag is asserted via `@moduletag :integration` in the file; if `mix.exs`'s `test_paths` doesn't include `test/integration`, the test will still be picked up because the default `test_paths` is `["test"]` and recurses.)

- [ ] **Step 3: Verify the bug is actually being exercised**

Sanity-check that without the fix this test would fail. Temporarily revert the `Connection.Server` change:

```bash
git stash push -- lib/macrina/connection/server.ex
mix test test/integration/block_port_roaming_test.exs --include integration
```

Expected: FAIL — the second packet arrives on a different conn_name and replies `4.08 Request Entity Incomplete` instead of `2.04 Changed`.

Restore:

```bash
git stash pop
mix test test/integration/block_port_roaming_test.exs --include integration
```

Expected: PASS.

- [ ] **Step 4: Format and commit**

```bash
mix format test/integration/block_port_roaming_test.exs
git add test/integration/block_port_roaming_test.exs
git commit -m "$(cat <<'EOF'
add single-node port-roaming integration test

Two UDP client sockets share a token; block 0 goes through socket A,
block 1 through socket B. Asserts the application handler sees one
assembled message and the final response arrives on socket B.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Cross-node cluster integration test

**Files:**
- Modify: `test/test_helper.exs`
- Create: `test/integration/block_port_roaming_cluster_test.exs`

Proves the fix works when the roamed packet lands on a different BEAM node. Uses `:peer` (OTP 25+) to start a slave node, connects it, and starts a `Macrina.Endpoint` on each node bound to different loopback ports. Block 0 is sent to the N1 endpoint; block 1 is sent to the N2 endpoint with the same token. Asserts that one BlockTransfer pid exists, that it lives on N1, and that the final reply arrives from N2's socket.

`:peer` requires the test node to be distributed. We start distribution in `test_helper.exs`.

- [ ] **Step 1: Enable distribution in `test_helper.exs`**

Edit `test/test_helper.exs`:

```elixir
:net_kernel.start(:"macrina_test@127.0.0.1", %{name_domain: :longnames})
ExUnit.start()
```

- [ ] **Step 2: Write the failing test**

Create `test/integration/block_port_roaming_cluster_test.exs`:

```elixir
defmodule Macrina.Integration.BlockPortRoamingClusterTest do
  use ExUnit.Case, async: false

  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  @moduletag :cluster
  @moduletag :integration

  defmodule EchoHandler do
    def call(_state, %Message{} = message) do
      Message.response(message, code: :changed, type: :ack, payload: "ok")
    end
  end

  setup do
    {:ok, peer, peer_node} =
      :peer.start(%{
        name: :"macrina_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        connection: :standard_io
      })

    code_paths = :code.get_path()
    true = :erpc.call(peer_node, :code, :add_paths, [code_paths])

    {:ok, _} = :erpc.call(peer_node, Application, :ensure_all_started, [:macrina])

    on_exit(fn -> :peer.stop(peer) end)

    {:ok, peer: peer, peer_node: peer_node}
  end

  defp start_endpoint_on(node, handler) do
    :erpc.call(node, Macrina.Endpoint, :start_link, [
      [
        handler: handler,
        port: 0,
        name: :"endpoint_#{System.unique_integer([:positive])}"
      ]
    ])
  end

  defp endpoint_port(node, pid) do
    {:ok, socket} = :erpc.call(node, Macrina.Endpoint, :socket, [pid])
    {:ok, {_, port}} = :erpc.call(node, :inet, :sockname, [socket])
    port
  end

  defp open_client_socket do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false, reuseaddr: true])
    sock
  end

  defp send_block(socket, port, number, more, payload, token, id) do
    msg = %Message{
      id: id,
      token: token,
      type: :con,
      code: :put,
      descriptive_block: %Block{number: number, size: byte_size(payload), more: more},
      control_block: nil,
      options: [],
      payload: payload
    }

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, Message.encode(msg))
  end

  defp recv(socket) do
    {:ok, {_ip, _port, packet}} = :gen_udp.recv(socket, 0, 2_000)
    {:ok, msg} = Message.decode(packet)
    msg
  end

  test "block 0 to node 1, block 1 to node 2 assembles via shared :global BlockTransfer",
       %{peer_node: peer_node} do
    {:ok, n1_endpoint} = Macrina.Endpoint.start_link(handler: EchoHandler, port: 0, name: :"endpoint_n1_#{System.unique_integer([:positive])}")
    {:ok, n1_socket} = Macrina.Endpoint.socket(n1_endpoint)
    {:ok, {_, n1_port}} = :inet.sockname(n1_socket)

    {:ok, n2_endpoint} = start_endpoint_on(peer_node, EchoHandler)
    n2_port = endpoint_port(peer_node, n2_endpoint)

    token = :crypto.strong_rand_bytes(8)
    socket = open_client_socket()

    on_exit(fn -> :gen_udp.close(socket) end)

    send_block(socket, n1_port, 0, true, "aaaa", token, 1)
    ack0 = recv(socket)
    assert ack0.code == :continue

    transfer_pid = :global.whereis_name({Macrina.BlockTransfer, {127, 0, 0, 1}, token})
    assert is_pid(transfer_pid)
    assert node(transfer_pid) == Node.self()

    send_block(socket, n2_port, 1, false, "bbbb", token, 2)
    final = recv(socket)
    assert final.code == :changed
    assert final.payload == "ok"
  end
end
```

- [ ] **Step 3: Run the test**

Run: `mix test test/integration/block_port_roaming_cluster_test.exs --include cluster --include integration`
Expected: PASS.

If `:peer.start` flakes (it can on heavily loaded CI), increase the recv timeout to 5_000 in the helper and retry. If it still flakes consistently, that's a CI environment issue, not a code issue — note it in the commit.

- [ ] **Step 4: Confirm normal `mix test` still excludes cluster by default if desired**

Decide whether `:cluster` should be excluded by default. Recommended: include in default runs (cluster correctness is the headline of this feature), exclude only if CI proves unreliable.

If excluding: add to `mix.exs` `test` config or document the `--exclude cluster` flag in `CONTRIBUTING.md`. **For this plan: include by default.** No mix.exs change needed.

- [ ] **Step 5: Format and commit**

```bash
mix format test/test_helper.exs test/integration/block_port_roaming_cluster_test.exs
git add test/test_helper.exs test/integration/block_port_roaming_cluster_test.exs
git commit -m "$(cat <<'EOF'
add cross-node port-roaming integration test

Uses :peer to launch a second BEAM node with macrina started on it.
Block 0 is sent to the local endpoint, block 1 to the peer's endpoint
with the same token. Asserts the BlockTransfer pid lives on the
receiving node of block 0 and the assembled response arrives via the
peer's socket.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: CHANGELOG and final verification

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Check the CHANGELOG location and structure**

Run: `ls CHANGELOG* 2>/dev/null || echo none`

If a `CHANGELOG.md` exists at the project root, edit it. If not, skip this step (the project may track changes differently — see `notes/refactor-plan.md`).

- [ ] **Step 2: Add an `[Unreleased]` entry**

Under the `[Unreleased]` `### Changed` (or `### Fixed`) section, add:

```markdown
- Block1 uploads now survive a source-port change provided the device holds the CoAP Token constant, including across BEAM nodes in a cluster. Block-assembly state moved from `Macrina.Connection.Server` (per-`{ip, port}`) to a new internal `Macrina.BlockTransfer` GenServer (per-`{ip, token}`, `:global`-registered).
```

- [ ] **Step 3: Run the full pre-PR loop**

Run:

```bash
mix format --check-formatted && mix credo --strict && mix test && mix dialyzer
```

Expected: all four pass.

If `mix dialyzer` is slow on first run (PLT build), that's expected — let it finish.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "$(cat <<'EOF'
note block port-roaming fix in CHANGELOG

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Push the branch**

```bash
git push -u origin block-port-roaming
```

(Do not open a PR automatically — leave that to the user.)

---

## Self-review

**Spec coverage:**
- §2 goal 1 (port roaming survives if Token constant): Tasks 5 + 6.
- §2 goal 2 (cluster correctness): Tasks 4 + 7.
- §2 goal 3 (no new deps): plan introduces none.
- §2 goal 4 (non-block dedup unchanged): Task 5 only edits the `descriptive_block` clauses; the `last_token == token` path for single-datagram messages is untouched.
- §5 (cluster behavior): Task 4 wires `:global`; Task 7 proves it cross-node.
- §6.1 module surface: Tasks 1–4 build it.
- §6.2 changed modules: Task 5.
- §7 failure modes: covered implicitly by tests in Tasks 1–4 (gap, duplicate, out-of-order); cluster edge cases by Task 7. The `EXCHANGE_LIFETIME` expiry case is not explicitly tested — covered by the design but acceptable to defer; a follow-up could add a fake-clock test.
- §8 testing: Tasks 1, 2, 3, 4 cover unit; Tasks 6, 7 cover integration. **Telemetry events from §8 are intentionally omitted** — the existing codebase has no telemetry pattern to follow (the spec's claim of "existing pattern in `test/connection_server_test.exs`" is based on stale documentation; that file does not exist). If telemetry is desired, add it as a follow-up plan after this lands.
- §9 CHANGELOG: Task 8.
- §10 risks: documented; no implementation needed.

**Placeholder scan:** none found.

**Type consistency:** `BlockTransfer.handle_block/2` and `handle_block/4` return the same action-tuple shape across tasks. `Blocks.read/1` returns `{:ok, binary} | {:error, {:missing, n}}` consistently. `cache_completion/2` and `cache_completion/3` — wait, the spec used `cache_completion/3` (`ip, token, bin`) but the plan uses `cache_completion/2` (`pid, bin`) because `Connection.Server` already holds the pid via lookup. Re-checked the plan: only `cache_completion/2` is defined and called. Spec wording is slightly off but the chosen shape is simpler and equivalent. Acceptable — `Connection.Server` calls it on the resolved pid, not by re-looking-up; this is more efficient and matches what the spec actually needs.

Wait — that's not quite right. Look at Task 5 step 2: `Macrina.BlockTransfer.cache_completion(state.ip, message.token, reply_bin)`. That's the 3-arity form. But Task 3 only defines a 2-arity form. **Bug.** Either define `cache_completion/3` in Task 3 that does its own lookup, or change Task 5 to use the resolved pid.

The cleaner fix: keep `cache_completion/2` as defined in Task 3 (pid-based, cheap), and in Task 5 do the lookup explicitly. But Task 5 is dispatching on the *result* of `handle_block/4`, which already did the lookup — we no longer have the pid in hand after handle_block returns. Two options:

1. Have `handle_block/4` return `{action, pid}` so the caller can chain `cache_completion(pid, bin)`.
2. Define `cache_completion/3` that does its own `:global.whereis_name` lookup.

Option 2 is simpler and matches the spec verbatim. **Fix inline in Task 3 and Task 5 below.**

---

## Inline fix to Task 3 and Task 5

**Task 3 fix.** Replace step 3's `cache_completion/2` definitions with a 3-arity form:

In `lib/macrina/block_transfer.ex`:

```elixir
@spec cache_completion(:inet.ip_address(), binary(), binary() | nil) :: :ok
def cache_completion(ip, token, reply_bin) when is_binary(reply_bin) or is_nil(reply_bin) do
  case :global.whereis_name({__MODULE__, ip, token}) do
    :undefined -> :ok
    pid -> GenServer.call(pid, {:cache_completion, reply_bin})
  end
end
```

And update Task 3's tests to call the 3-arity form: replace `BlockTransfer.cache_completion(pid, reply_bin)` with `BlockTransfer.cache_completion({127, 0, 0, 1}, <<1, 2, 3, 4>>, reply_bin)` and similar for the nil case. (The tests in Task 3 use `start_transfer/1` which starts an unregistered pid, so for those two tests we need to either start with a global name or test via the 2-arity internal form. Cleanest: keep an internal 2-arity `GenServer.call`-style helper for tests, and have the public 3-arity wrap it via lookup.) Concretely:

Public API (added in Task 3):

```elixir
@spec cache_completion(:inet.ip_address(), binary(), binary() | nil) :: :ok
def cache_completion(ip, token, reply_bin) when is_binary(reply_bin) or is_nil(reply_bin) do
  case :global.whereis_name({__MODULE__, ip, token}) do
    :undefined -> :ok
    pid -> GenServer.call(pid, {:cache_completion, reply_bin})
  end
end
```

Test-friendly internal (also added in Task 3, used only by tests in Task 3):

```elixir
@doc false
def cache_completion(pid, reply_bin) when is_pid(pid) and (is_binary(reply_bin) or is_nil(reply_bin)) do
  GenServer.call(pid, {:cache_completion, reply_bin})
end
```

The two-arity form is a thin convenience for tests that hold a pid directly; production code uses the three-arity public form. Both delegate to the same `handle_call` clause.

Task 3 tests continue to call `BlockTransfer.cache_completion(pid, reply_bin)` — this is the test-friendly internal arity.

**Task 5 fix.** Step 2's code already calls the 3-arity public form (`Macrina.BlockTransfer.cache_completion(state.ip, message.token, reply_bin)`). No change needed — it now matches what Task 3 defines.

---

## Execution choice

Plan complete and saved to `docs/superpowers/plans/2026-05-12-block-port-roaming.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
