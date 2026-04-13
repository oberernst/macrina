defmodule Macrina.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Macrina.{Discovery, Discovery.Resource, Request, Response}

  test "encodes discovery resources as CoRE Link Format" do
    resource =
      Resource.new!("/sensors/temperature c",
        rt: "temperature-c",
        ct: [0, 50],
        obs: true
      )

    assert {:ok, payload} = Discovery.encode([resource])
    assert payload == "</sensors/temperature%20c>;rt=\"temperature-c\";ct=\"0 50\";obs"
  end

  test "discovery responses return not acceptable when the request asks for another format" do
    request =
      Request.new(:get,
        path: Discovery.well_known_core_path(),
        accept: :application_json
      )

    resource = Resource.new!("/status", rt: "health")

    assert {:ok, response} = Discovery.response([resource], request)
    assert response.code == :not_acceptable
    assert Response.content_format(response) == nil
  end

  test "resource validation rejects unsupported attribute values" do
    assert {:error, {:invalid_attribute_value, %{bad: true}}} =
             Resource.new("/status", rt: %{bad: true})
  end
end
