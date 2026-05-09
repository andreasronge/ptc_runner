defmodule PtcRunnerMcp.CredentialsBindingTest do
  @moduledoc """
  Spec-shape validation for `Credentials.Binding.parse/2` and
  `parse_block/1`.

  Spec: `Plans/http-transport-credentials.md` §5.4, §5.4.1, §5.4.2,
  §5.5 ##1, 4, 7 (first bullet), 11, §7.2.

  These tests verify shape validation only — `parse/2` is pure and
  must not touch the environment, the filesystem, or the network.
  Resolution lives in 1B (`Credentials.materialize/1`).
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Credentials.Binding

  describe "parse/2 — env source" do
    test "happy path: minimal env binding" do
      assert {:ok, %Binding{} = b} =
               Binding.parse("github_pat", %{"source" => "env", "var" => "GITHUB_PAT"})

      assert b.name == "github_pat"
      assert b.source == :env
      assert b.scheme_hint == nil
      assert b.spec == %{var: "GITHUB_PAT"}
    end

    test "missing var field" do
      assert {:error, :missing_field, msg} =
               Binding.parse("b", %{"source" => "env"})

      assert msg =~ "binding 'b'"
      assert msg =~ "var"
    end

    test "var must be a non-empty string" do
      assert {:error, :invalid_field, _} =
               Binding.parse("b", %{"source" => "env", "var" => ""})

      assert {:error, :invalid_field, _} =
               Binding.parse("b", %{"source" => "env", "var" => 42})
    end

    test "var must match env-var identifier grammar" do
      assert {:error, :invalid_env_var, msg} =
               Binding.parse("b", %{"source" => "env", "var" => "9HAS_DIGIT"})

      assert msg =~ "binding 'b'"

      assert {:error, :invalid_env_var, _} =
               Binding.parse("b", %{"source" => "env", "var" => "HAS-DASH"})

      assert {:error, :invalid_env_var, _} =
               Binding.parse("b", %{"source" => "env", "var" => "HAS SPACE"})
    end

    test "underscore-leading and mixed-case env vars are accepted" do
      assert {:ok, %Binding{spec: %{var: "_PRIVATE"}}} =
               Binding.parse("b", %{"source" => "env", "var" => "_PRIVATE"})

      assert {:ok, %Binding{spec: %{var: "MixedCase_1"}}} =
               Binding.parse("b", %{"source" => "env", "var" => "MixedCase_1"})
    end
  end

  describe "parse/2 — file source" do
    test "happy path: minimal file binding" do
      assert {:ok, %Binding{} = b} =
               Binding.parse("svc_key", %{"source" => "file", "path" => "/etc/secrets/svc"})

      assert b.source == :file
      assert b.spec == %{path: "/etc/secrets/svc"}
    end

    test "missing path field" do
      assert {:error, :missing_field, _} =
               Binding.parse("b", %{"source" => "file"})
    end

    test "path must be a non-empty string" do
      assert {:error, :invalid_field, _} =
               Binding.parse("b", %{"source" => "file", "path" => ""})

      assert {:error, :invalid_field, _} =
               Binding.parse("b", %{"source" => "file", "path" => nil})
    end

    test "does not check the file exists at parse time" do
      # /no/such/path is fine at parse — resolution is 1B's job.
      assert {:ok, %Binding{}} =
               Binding.parse("b", %{
                 "source" => "file",
                 "path" => "/definitely/does/not/exist/zzz"
               })
    end
  end

  describe "parse/2 — literal source" do
    test "happy path: literal string value" do
      assert {:ok, %Binding{} = b} =
               Binding.parse("dev_token", %{"source" => "literal", "value" => "sk-abc"})

      assert b.source == :literal
      assert b.spec == %{value: "sk-abc"}
    end

    test "value is required" do
      assert {:error, :missing_field, _} =
               Binding.parse("b", %{"source" => "literal"})
    end

    test "value must be a string" do
      assert {:error, :invalid_literal, _} =
               Binding.parse("b", %{"source" => "literal", "value" => 123})

      assert {:error, :invalid_literal, _} =
               Binding.parse("b", %{"source" => "literal", "value" => nil})
    end

    test "empty-string value is rejected" do
      assert {:error, :invalid_literal, _} =
               Binding.parse("b", %{"source" => "literal", "value" => ""})
    end
  end

  describe "parse/2 — exec source (deferred to v1.1)" do
    test "exec is rejected with v1.1-deferral error" do
      assert {:error, :exec_deferred, msg} =
               Binding.parse("dangerous", %{
                 "source" => "exec",
                 "command" => ["/usr/bin/secrets"]
               })

      assert msg =~ "binding 'dangerous'"
      assert msg =~ "deferred to v1.1"
      assert msg =~ "allow_exec_bindings"
    end
  end

  describe "parse/2 — source field" do
    test "missing source" do
      assert {:error, :missing_source, _} =
               Binding.parse("b", %{"var" => "X"})
    end

    test "unknown source" do
      assert {:error, :unknown_source, msg} =
               Binding.parse("b", %{"source" => "vault"})

      assert msg =~ "vault"
    end

    test "non-string source" do
      assert {:error, :unknown_source, _} =
               Binding.parse("b", %{"source" => 1})
    end
  end

  describe "parse/2 — scheme_hint" do
    test "absent → nil" do
      assert {:ok, %Binding{scheme_hint: nil}} =
               Binding.parse("b", %{"source" => "env", "var" => "X"})
    end

    test "valid hints round-trip to atoms" do
      for {str, atom} <- [{"bearer", :bearer}, {"basic", :basic}, {"raw", :raw}] do
        assert {:ok, %Binding{scheme_hint: ^atom}} =
                 Binding.parse("b", %{
                   "source" => "env",
                   "var" => "X",
                   "scheme_hint" => str
                 })
      end
    end

    test "unknown scheme_hint is rejected" do
      assert {:error, :unknown_scheme_hint, msg} =
               Binding.parse("b", %{
                 "source" => "env",
                 "var" => "X",
                 "scheme_hint" => "oauth"
               })

      assert msg =~ "oauth"
    end

    test "non-string scheme_hint is rejected" do
      assert {:error, :unknown_scheme_hint, _} =
               Binding.parse("b", %{
                 "source" => "env",
                 "var" => "X",
                 "scheme_hint" => 7
               })
    end
  end

  describe "parse/2 — unknown field rejection (typo guard)" do
    test "unknown top-level key is loud-fail" do
      # Catch typos like "sourec" or "valeu".
      assert {:error, :unknown_field, msg} =
               Binding.parse("b", %{"source" => "env", "var" => "X", "vra" => "Y"})

      assert msg =~ "vra"
    end

    test "wrong source's field is rejected (e.g., 'path' on env)" do
      assert {:error, :unknown_field, _} =
               Binding.parse("b", %{
                 "source" => "env",
                 "var" => "X",
                 "path" => "/etc/x"
               })
    end

    test "non-map raw spec is rejected" do
      assert {:error, :invalid_spec, _} = Binding.parse("b", "not a map")
    end
  end

  describe "parse_block/1" do
    test "nil block → empty map" do
      assert {:ok, %{}} = Binding.parse_block(nil)
    end

    test "empty block → empty map" do
      assert {:ok, %{}} = Binding.parse_block(%{})
    end

    test "accumulates multiple bindings" do
      block = %{
        "gh" => %{"source" => "env", "var" => "GITHUB_PAT", "scheme_hint" => "bearer"},
        "svc" => %{"source" => "file", "path" => "/etc/svc"},
        "dev" => %{"source" => "literal", "value" => "sk-dev"}
      }

      assert {:ok, parsed} = Binding.parse_block(block)
      assert map_size(parsed) == 3
      assert %Binding{source: :env, scheme_hint: :bearer} = parsed["gh"]
      assert %Binding{source: :file} = parsed["svc"]
      assert %Binding{source: :literal} = parsed["dev"]
      assert parsed["gh"].name == "gh"
      assert parsed["svc"].name == "svc"
      assert parsed["dev"].name == "dev"
    end

    test "first failure short-circuits with binding name in detail" do
      block = %{
        "good" => %{"source" => "env", "var" => "X"},
        "bad" => %{"source" => "exec", "command" => ["x"]}
      }

      assert {:error, :exec_deferred, msg} = Binding.parse_block(block)
      assert msg =~ "binding 'bad'"
    end

    test "rejects unsafe binding names" do
      assert {:error, :invalid_binding_name, msg} =
               Binding.parse_block(%{
                 "has space" => %{"source" => "env", "var" => "X"}
               })

      assert msg =~ "has space"

      assert {:error, :invalid_binding_name, _} =
               Binding.parse_block(%{
                 "1leading_digit" => %{"source" => "env", "var" => "X"}
               })

      assert {:error, :invalid_binding_name, _} =
               Binding.parse_block(%{
                 "weird$char" => %{"source" => "env", "var" => "X"}
               })
    end

    test "accepts hyphens, underscores, and digits after first letter" do
      block = %{
        "a-b_c-1" => %{"source" => "env", "var" => "X"}
      }

      assert {:ok, %{"a-b_c-1" => %Binding{}}} = Binding.parse_block(block)
    end
  end
end
