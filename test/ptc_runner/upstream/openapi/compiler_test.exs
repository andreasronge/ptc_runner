defmodule PtcRunner.Upstream.OpenAPI.CompilerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Upstream.OpenAPI.Compiler

  # The compiler is a v1 security guardrail: it only emits tools for read-only
  # GET operations that return JSON from the configured origin. Each rejection
  # branch carries a distinguishing {:error, :upstream_unavailable, msg} signal
  # that surfaces to the LLM; we assert stable substrings of those messages.

  @base_url "https://api.example.com"

  # Builds an OpenAPI schema with a single operation at GET /widgets that
  # passes every guard, then lets callers mutate just the operation under test.
  defp schema_with(operation, opts \\ []) do
    path = Keyword.get(opts, :path, "/widgets")

    %{
      "paths" => %{
        path => %{
          Keyword.get(opts, :method, "get") => operation
        }
      }
    }
  end

  defp ok_operation(extra \\ %{}) do
    Map.merge(
      %{
        "operationId" => "listWidgets",
        "summary" => "List widgets",
        "responses" => %{
          "200" => %{
            "content" => %{
              "application/json" => %{"schema" => %{"type" => "array"}}
            }
          }
        }
      },
      extra
    )
  end

  defp config(includes \\ ["listWidgets"], overrides \\ %{}) do
    %{base_url: @base_url, include_operations: includes, operation_overrides: overrides}
  end

  describe "compile/2 happy paths" do
    test "compiles a GET JSON operation into a read-only tool" do
      assert {:ok, [tool]} = Compiler.compile(schema_with(ok_operation()), config())

      assert tool["name"] == "list-widgets"
      assert tool["annotations"] == %{"readOnlyHint" => true}
      assert tool["_ptc"]["transport"] == "openapi"
      assert tool["_ptc"]["method"] == "GET"
      assert tool["_ptc"]["path"] == "/widgets"
      assert tool["outputSchema"] == %{"type" => "array"}
      assert tool["description"] == "List widgets"
    end

    test "x-ptc-name overrides the exposed (normalized) name" do
      op = ok_operation(%{"x-ptc-name" => "MyWidgets"})

      assert {:ok, [tool]} = Compiler.compile(schema_with(op), config())
      assert tool["name"] == "my-widgets"
    end

    test "operation_overrides name/description win over the schema" do
      overrides = %{
        "listWidgets" => %{"name" => "OverrideName", "description" => "override desc"}
      }

      assert {:ok, [tool]} =
               Compiler.compile(schema_with(ok_operation()), config(["listWidgets"], overrides))

      assert tool["name"] == "override-name"
      assert tool["description"] == "override desc"
    end

    test "x-ptc-default-args drops the arg from required and carries defaults" do
      op =
        ok_operation(%{
          "parameters" => [
            %{"name" => "region", "in" => "query", "required" => true, "schema" => %{}}
          ],
          "x-ptc-default-args" => %{"region" => "us"}
        })

      assert {:ok, [tool]} = Compiler.compile(schema_with(op), config())
      assert tool["_ptc"]["defaultArgs"] == %{"region" => "us"}
      refute "region" in tool["inputSchema"]["required"]
      assert tool["inputSchema"]["properties"]["region"]["type"] == "string"
    end

    test "204-only success yields a null output schema" do
      op =
        ok_operation(%{
          "responses" => %{"204" => %{"description" => "no content"}}
        })

      assert {:ok, [tool]} = Compiler.compile(schema_with(op), config())
      assert tool["outputSchema"] == %{"type" => "null"}
    end

    test "path parameter becomes a required string property" do
      op =
        ok_operation(%{
          "operationId" => "getWidget",
          "parameters" => [
            %{"name" => "id", "in" => "path", "required" => true, "schema" => %{}}
          ]
        })

      schema = schema_with(op, path: "/widgets/{id}")

      assert {:ok, [tool]} = Compiler.compile(schema, config(["getWidget"]))
      assert tool["inputSchema"]["required"] == ["id"]
      assert tool["inputSchema"]["properties"]["id"]["type"] == "string"
    end
  end

  describe "compile/2 rejection branches" do
    test "non-GET method is rejected" do
      schema = schema_with(ok_operation(%{"operationId" => "createWidget"}), method: "post")

      assert {:error, :upstream_unavailable, msg} =
               Compiler.compile(schema, config(["createWidget"]))

      assert msg =~ "unsupported method POST"
      assert msg =~ "GET only"
    end

    test "deprecated operation is rejected" do
      op = ok_operation(%{"deprecated" => true})

      assert {:error, :upstream_unavailable, msg} = Compiler.compile(schema_with(op), config())
      assert msg =~ "is deprecated"
    end

    test "operation with a requestBody is rejected" do
      op = ok_operation(%{"requestBody" => %{"content" => %{}}})

      assert {:error, :upstream_unavailable, msg} = Compiler.compile(schema_with(op), config())
      assert msg =~ "has requestBody"
    end

    test "$ref parameter is rejected" do
      op = ok_operation(%{"parameters" => [%{"$ref" => "#/components/parameters/Foo"}]})

      assert {:error, :upstream_unavailable, msg} = Compiler.compile(schema_with(op), config())
      assert msg =~ "$ref parameters are unsupported"
    end

    test "header parameter is rejected" do
      op =
        ok_operation(%{"parameters" => [%{"name" => "X-Trace", "in" => "header"}]})

      assert {:error, :upstream_unavailable, msg} = Compiler.compile(schema_with(op), config())
      assert msg =~ "unsupported header parameter"
    end

    test "cookie parameter is rejected" do
      op =
        ok_operation(%{"parameters" => [%{"name" => "sid", "in" => "cookie"}]})

      assert {:error, :upstream_unavailable, msg} = Compiler.compile(schema_with(op), config())
      assert msg =~ "unsupported cookie parameter"
    end

    test "cross-origin server URL is rejected" do
      op =
        ok_operation(%{"servers" => [%{"url" => "https://evil.example.net"}]})

      assert {:error, :upstream_unavailable, msg} = Compiler.compile(schema_with(op), config())
      assert msg =~ "cross-origin servers"
    end

    test "same-origin server URL is accepted" do
      op = ok_operation(%{"servers" => [%{"url" => "https://api.example.com/v2"}]})

      assert {:ok, [_tool]} = Compiler.compile(schema_with(op), config())
    end

    test "operation with no 2xx response is rejected" do
      op =
        ok_operation(%{
          "responses" => %{"404" => %{"description" => "missing"}}
        })

      assert {:error, :upstream_unavailable, msg} = Compiler.compile(schema_with(op), config())
      assert msg =~ "no 2xx response"
    end

    test "2xx response that is not JSON is rejected" do
      op =
        ok_operation(%{
          "responses" => %{
            "200" => %{"content" => %{"text/csv" => %{"schema" => %{"type" => "string"}}}}
          }
        })

      assert {:error, :upstream_unavailable, msg} = Compiler.compile(schema_with(op), config())
      assert msg =~ "no JSON 2xx response"
    end

    test "name collision after normalization is rejected" do
      schema = %{
        "paths" => %{
          "/widgets" => %{"get" => ok_operation(%{"operationId" => "listWidgets"})},
          "/gadgets" => %{
            "get" => ok_operation(%{"operationId" => "list_widgets"})
          }
        }
      }

      assert {:error, :upstream_unavailable, msg} =
               Compiler.compile(schema, config(["listWidgets", "list_widgets"]))

      assert msg =~ "name collision after normalization"
      assert msg =~ "list-widgets"
    end

    test "path template missing a declared path parameter is rejected" do
      # The path has {id} in the template but no path parameter declares it.
      op = ok_operation(%{"operationId" => "getWidget"})
      schema = schema_with(op, path: "/widgets/{id}")

      assert {:error, :upstream_unavailable, msg} =
               Compiler.compile(schema, config(["getWidget"]))

      assert msg =~ "missing declared path parameter"
      assert msg =~ "id"
    end

    test "include_operations referencing an unknown operation is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               Compiler.compile(schema_with(ok_operation()), config(["nope"]))

      assert msg =~ "include_operations not found"
      assert msg =~ "nope"
    end
  end
end
