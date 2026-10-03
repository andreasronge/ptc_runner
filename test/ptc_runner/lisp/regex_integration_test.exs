defmodule PtcRunner.Lisp.RegexIntegrationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "regex safety at the interpreter boundary" do
    test "truncation preserves UTF-8 codepoints" do
      input = String.duplicate("a", 32_767) <> "é"

      assert {:ok, %{return: "a"}} =
               Lisp.run(~S|(re-find #"a" data/input)|, context: %{input: input})
    end

    test "replace reports excessive regex complexity" do
      input = String.duplicate("a", 30) <> "!"

      assert {:error, %{fail: %{message: message}}} =
               Lisp.run(~S|(replace data/input #"(a+)+$" "x")|, context: %{input: input})

      assert message =~ "Regex complexity limit exceeded"
    end
  end

  describe "uniform regex limits" do
    test "all regex operations report malformed UTF-8" do
      for source <- [
            ~S|(re-find #"a" data/input)|,
            ~S|(re-matches #"a" data/input)|,
            ~S|(re-seq #"a" data/input)|,
            ~S|(re-split #"a" data/input)|,
            ~S|(split data/input #"a")|,
            ~S|(replace data/input #"a" "b")|,
            ~S|(extract "(a)" data/input)|,
            ~S|(extract-int "(a)" data/input)|
          ] do
        assert {:error, %{fail: %{message: message}}} =
                 Lisp.run(source, context: %{input: <<97, 255>>})

        assert message =~ "valid UTF-8", source
      end
    end

    test "global scans report complexity failures instead of partial results" do
      for source <- [
            ~S|(re-seq #"(a+)+$" data/input)|,
            ~S|(re-split #"(a+)+$" data/input)|,
            ~S|(split data/input #"(a+)+$")|
          ] do
        assert {:error, %{fail: %{message: message}}} =
                 Lisp.run(source, context: %{input: String.duplicate("a", 30) <> "!"})

        assert message =~ "Regex complexity limit exceeded", source
      end
    end

    test "literal analysis and dynamic patterns enforce the pattern cap" do
      pattern = String.duplicate("a", 257)

      assert {:error, %{fail: %{reason: :invalid_form, message: message}}} =
               Lisp.run("#\"#{pattern}\"")

      assert message =~ "maximum length of 256 bytes"

      assert {:error, %{fail: %{message: message}}} =
               Lisp.run(~S|(re-pattern data/pattern)|, context: %{pattern: pattern})

      assert message =~ "maximum length of 256 bytes"
    end

    test "split and replace truncate at complete codepoints for every UTF-8 width" do
      for char <- ["é", "€", "😀"], cut <- 1..(byte_size(char) - 1) do
        prefix = String.duplicate("a", 32_768 - cut)
        input = prefix <> char <> "tail"

        assert {:ok, %{return: [^prefix]}} =
                 Lisp.run(~S|(re-split #"," data/input)|, context: %{input: input})

        assert {:ok, %{return: ^prefix}} =
                 Lisp.run(~S|(replace data/input #"tail" "x")|, context: %{input: input})

        assert {:ok, %{return: nil}} =
                 Lisp.run(~S|(re-find #"tail" data/input)|, context: %{input: input})
      end
    end

    test "Unicode classes agree between literals and dynamic patterns" do
      assert {:ok, %{return: ["é", "é"]}} =
               Lisp.run(~S|[(re-find #"\w" "é") (re-find (re-pattern "\\w") "é")]|)
    end

    test "split captures and replacement backreferences keep Erlang semantics" do
      assert {:ok, %{return: ["a", ",", "", ",", "b", ",", ""]}} =
               Lisp.run(~S|(re-split #"(,)" "a,,b,")|)

      assert {:ok, %{return: "[12:12]"}} =
               Lisp.run(~S|(replace "12" #"(\d+)" "[\\1:&]")|)

      assert {:ok, %{return: "xaxbx"}} = Lisp.run(~S|(replace "ab" #"" "x")|)
    end
  end

  describe "re-split via interpreter" do
    test "splits by simple regex pattern" do
      source = ~S|(re-split (re-pattern ",") "a,b,c")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["a", "b", "c"]
    end

    test "splits by whitespace pattern" do
      source = ~S|(re-split (re-pattern "\\s+") "a  b   c")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["a", "b", "c"]
    end

    test "splits by newlines" do
      source = ~S|(re-split (re-pattern "\\r?\\n") "line1\nline2\r\nline3")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["line1", "line2", "line3"]
    end

    test "works in pipeline" do
      source = ~S|(->> "a  b   c" (re-split (re-pattern "\\s+")) count)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 3
    end
  end

  describe "re-seq via interpreter" do
    test "finds all matches" do
      source = ~S|(re-seq (re-pattern "\\d+") "a1b22c333")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["1", "22", "333"]
    end

    test "returns empty list when no matches" do
      source = ~S|(re-seq (re-pattern "\\d+") "abc")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "returns groups when pattern has capture groups" do
      source = ~S|(re-seq (re-pattern "(\\d)(\\w)") "1a2b3c")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [["1a", "1", "a"], ["2b", "2", "b"], ["3c", "3", "c"]]
    end

    test "works in pipeline" do
      source = ~S|(->> "foo1bar2baz3" (re-seq (re-pattern "\\d+")) count)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 3
    end
  end

  describe "regex literal #\"...\"" do
    test "produces a compiled regex" do
      source = ~S|#"\d+"|
      {:ok, %{return: result}} = Lisp.run(source)
      # re-pattern returns an Erlang compiled regex (re_mp tuple)
      assert {:re_mp, _, _, _} = result
    end

    test "works with re-split" do
      source = ~S|(re-split #"\s+" "a b c")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["a", "b", "c"]
    end

    test "works with re-find" do
      source = ~S|(re-find #"(\d+)" "abc123")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["123", "123"]
    end

    test "works with re-seq" do
      source = ~S|(re-seq #"\d+" "a1b2c3")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["1", "2", "3"]
    end

    test "invalid regex is caught at analysis time" do
      source = ~S|#"[a-z"|
      {:error, %{fail: %{reason: :invalid_form, message: message}}} = Lisp.run(source)
      assert message =~ "invalid regex literal"
      assert message =~ "missing terminating"
    end

    test "equivalent to re-pattern call" do
      source1 = ~S|(re-split #"," "a,b,c")|
      source2 = ~S|(re-split (re-pattern ",") "a,b,c")|
      {:ok, %{return: r1}} = Lisp.run(source1)
      {:ok, %{return: r2}} = Lisp.run(source2)
      assert r1 == r2
    end
  end

  describe "split accepts regex" do
    test "split with regex literal" do
      {:ok, %{return: result}} = Lisp.run(~S|(split "a  b c" #"\s+")|)
      assert result == ["a", "b", "c"]
    end

    test "split with re-pattern" do
      {:ok, %{return: result}} = Lisp.run(~S|(split "a1b2c" (re-pattern "\\d"))|)
      assert result == ["a", "b", "c"]
    end

    test "split still works with plain string" do
      {:ok, %{return: result}} = Lisp.run(~S|(split "a,b,c" ",")|)
      assert result == ["a", "b", "c"]
    end
  end

  describe "replace accepts regex" do
    test "replace with regex literal" do
      {:ok, %{return: result}} = Lisp.run(~S|(replace "a  b   c" #"\s+" " ")|)
      assert result == "a b c"
    end

    test "replace with re-pattern" do
      {:ok, %{return: result}} = Lisp.run(~S|(replace "abc123def" (re-pattern "\\d+") "X")|)
      assert result == "abcXdef"
    end

    test "replace still works with plain string" do
      {:ok, %{return: result}} = Lisp.run(~S|(replace "hello" "l" "r")|)
      assert result == "herro"
    end
  end
end
