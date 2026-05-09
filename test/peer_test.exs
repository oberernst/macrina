defmodule Macrina.PeerTest do
  use ExUnit.Case, async: true

  # `Macrina.Peer` is the home of small peer-identity helpers. The first one
  # is `label/2`, which formats an `{ip, port}` pair as the human-readable
  # string used in registry names and telemetry metadata.

  alias Macrina.Peer

  describe "label/2" do
    test "formats IPv4 tuples as dotted quad with /port" do
      assert Peer.label({127, 0, 0, 1}, 5683) == "127.0.0.1/5683"
    end

    test "formats IPv6 tuples as colon-separated hextets with /port" do
      assert Peer.label({0, 0, 0, 0, 0, 0, 0, 1}, 5683) == "0:0:0:0:0:0:0:1/5683"
    end

    test "preserves leading zeros in IPv4 octets as plain integers (no padding)" do
      # The function does not pad — it joins integers with dots verbatim.
      assert Peer.label({10, 0, 0, 1}, 1234) == "10.0.0.1/1234"
    end
  end
end
