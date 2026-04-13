defmodule Macrina.ResourceTest do
  use ExUnit.Case, async: true

  alias Macrina.{Request, Resource, Response, Router}

  test "router dispatch matches resources by exact path and method" do
    request = Request.from_uri!(:get, "/temperature")

    resource =
      Resource.new!("/temperature",
        attributes: [rt: "temperature-c", ct: [0]],
        get: Response.new(:content, payload: "22.3 C", content_format: :text_plain)
      )

    response = Router.dispatch([resource], request, %{})

    assert response.code == :content
    assert response.payload == "22.3 C"
    assert Response.content_format(response) == :text_plain
  end

  test "router dispatch negotiates responses by accept content format" do
    request = Request.from_uri!(:get, "/temperature", accept: :application_json)

    resource =
      Resource.new!("/temperature",
        get: [
          text_plain: Response.new(:content, payload: "22.3 C"),
          application_json: fn _request, _context ->
            Response.new(:content, payload: "{\"value\":\"22.3 C\"}")
          end
        ]
      )

    response = Resource.call(resource, request, %{})

    assert response.code == :content
    assert response.payload == "{\"value\":\"22.3 C\"}"
    assert Response.content_format(response) == :application_json
  end

  test "router dispatch returns not acceptable when no representation matches accept" do
    request = Request.from_uri!(:get, "/temperature", accept: :application_cbor)

    resource =
      Resource.new!("/temperature",
        get: [
          text_plain: Response.new(:content, payload: "22.3 C"),
          application_json: Response.new(:content, payload: "{\"value\":\"22.3 C\"}")
        ]
      )

    response = Resource.call(resource, request, %{})

    assert response.code == :not_acceptable
    assert Response.content_format(response) == nil
  end

  test "router discovery resources are derived from routing resources" do
    resource =
      Resource.new!("/temperature",
        attributes: [rt: "temperature-c", ct: [0, 50]],
        get: Response.new(:content, payload: "22.3 C", content_format: :text_plain)
      )

    assert {:ok, [discovery_resource]} = Router.discovery_resources([resource])
    assert discovery_resource.path == ["temperature"]
    assert discovery_resource.attributes == [{"rt", "temperature-c"}, {"ct", [0, 50]}]
  end

  test "router dispatch captures path params into the handler context" do
    request = Request.from_uri!(:get, "/devices/alpha")

    resource =
      Resource.new!("/devices/:device_id",
        discovery_path: "/devices",
        get: fn _request, context ->
          Response.new(:content,
            payload: Map.fetch!(context.path_params, :device_id),
            content_format: :text_plain
          )
        end
      )

    response = Router.dispatch([resource], request, %{})

    assert response.code == :content
    assert response.payload == "alpha"
    assert Response.content_format(response) == :text_plain
  end

  test "dynamic resources require an explicit discovery path unless hidden" do
    assert {:error, :dynamic_resource_requires_discovery_path} =
             Resource.new("/devices/:device_id",
               get: Response.new(:content, payload: "alpha")
             )

    assert {:error, :dynamic_resource_requires_discovery_path} =
             Resource.new("/files/*path",
               get: Response.new(:content, payload: "alpha")
             )

    assert {:ok, resource} =
             Resource.new("/devices/:device_id",
               discoverable: false,
               get: Response.new(:content, payload: "alpha")
             )

    assert :skip = Resource.discovery_resource(resource)
  end

  test "router discovery resources can use an explicit discovery path for parameterized routes" do
    resource =
      Resource.new!("/devices/:device_id",
        discovery_path: "/devices",
        attributes: [rt: "device"],
        get: Response.new(:content, payload: "alpha")
      )

    assert {:ok, [discovery_resource]} = Router.discovery_resources([resource])
    assert discovery_resource.path == ["devices"]
    assert discovery_resource.attributes == [{"rt", "device"}]
  end

  test "router dispatch captures wildcard path segments into the handler context" do
    request = Request.from_uri!(:get, "/files/archive/2026/report.txt")

    resource =
      Resource.new!("/files/*path",
        discovery_path: "/files",
        get: fn _request, context ->
          payload = Enum.join(Map.fetch!(context.path_params, :path), "/")
          Response.new(:content, payload: payload, content_format: :text_plain)
        end
      )

    response = Router.dispatch([resource], request, %{})

    assert response.code == :content
    assert response.payload == "archive/2026/report.txt"
    assert Response.content_format(response) == :text_plain
  end

  test "resource paths reject non-terminal wildcard segments" do
    assert {:error, :glob_must_be_terminal} =
             Resource.new("/files/*path/meta",
               discovery_path: "/files",
               get: Response.new(:content, payload: "bad")
             )
  end
end
