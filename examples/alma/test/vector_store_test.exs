defmodule Alma.VectorStoreTest do
  use ExUnit.Case, async: true

  alias Alma.VectorStore

  describe "embed/1" do
    test "is deterministic — same text produces same vector" do
      assert VectorStore.embed("hello world") == VectorStore.embed("hello world")
    end

    test "produces different vectors for different text" do
      refute VectorStore.embed("hello world") == VectorStore.embed("goodbye moon")
    end

    test "returns a map of n-gram frequencies (2-grams and 3-grams)" do
      vec = VectorStore.embed("aaa")
      assert vec == %{"aa" => 2, "aaa" => 1}
    end

    test "short strings (< 3 chars) still produce a non-empty vector" do
      vec = VectorStore.embed("ab")
      assert vec == %{"ab" => 1}
    end
  end

  describe "cosine_similarity/2 with sparse vectors" do
    test "identical vectors have similarity 1.0" do
      vec = VectorStore.embed("hello world")
      assert_in_delta VectorStore.cosine_similarity(vec, vec), 1.0, 1.0e-10
    end

    test "orthogonal vectors have similarity 0.0" do
      vec_a = %{"aaa" => 1}
      vec_b = %{"zzz" => 1}
      assert VectorStore.cosine_similarity(vec_a, vec_b) == 0.0
    end

    test "empty map returns 0.0" do
      assert VectorStore.cosine_similarity(%{}, %{"aaa" => 1}) == 0.0
      assert VectorStore.cosine_similarity(%{"aaa" => 1}, %{}) == 0.0
      assert VectorStore.cosine_similarity(%{}, %{}) == 0.0
    end
  end

  describe "cosine_similarity/2 with dense vectors" do
    test "identical vectors have similarity 1.0" do
      vec = [0.5, 0.3, 0.8]
      assert_in_delta VectorStore.cosine_similarity(vec, vec), 1.0, 1.0e-10
    end

    test "orthogonal vectors have similarity 0.0" do
      vec_a = [1.0, 0.0, 0.0]
      vec_b = [0.0, 1.0, 0.0]
      assert_in_delta VectorStore.cosine_similarity(vec_a, vec_b), 0.0, 1.0e-10
    end

    test "empty list returns 0.0" do
      assert VectorStore.cosine_similarity([], [1.0, 2.0]) == 0.0
      assert VectorStore.cosine_similarity([1.0, 2.0], []) == 0.0
    end

    test "opposite vectors have similarity -1.0" do
      vec_a = [1.0, 0.0]
      vec_b = [-1.0, 0.0]
      assert_in_delta VectorStore.cosine_similarity(vec_a, vec_b), -1.0, 1.0e-10
    end
  end

  describe "store and find_similar with sparse vectors" do
    test "stores and retrieves entries" do
      store = VectorStore.new()
      {1, store} = VectorStore.store(store, "the cat sat on the mat", VectorStore.embed("the cat sat on the mat"))
      {2, store} = VectorStore.store(store, "the dog sat on the log", VectorStore.embed("the dog sat on the log"))
      {3, store} = VectorStore.store(store, "quantum physics lecture notes", VectorStore.embed("quantum physics lecture notes"))

      results = VectorStore.find_similar(store, VectorStore.embed("the cat sat on the mat"), 2)

      assert length(results) == 2
      assert hd(results)["text"] == "the cat sat on the mat"
    end

    test "top-k ranking — most similar first" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "apple pie recipe", VectorStore.embed("apple pie recipe"))
      {_, store} = VectorStore.store(store, "apple crumble recipe", VectorStore.embed("apple crumble recipe"))
      {_, store} = VectorStore.store(store, "quantum mechanics textbook", VectorStore.embed("quantum mechanics textbook"))

      [first, second | _] = VectorStore.find_similar(store, VectorStore.embed("apple pie recipe"), 3)

      assert first["score"] >= second["score"]
      assert first["text"] == "apple pie recipe"
    end

    test "empty store returns empty list" do
      store = VectorStore.new()
      assert VectorStore.find_similar(store, VectorStore.embed("anything"), 5) == []
    end

    test "metadata is preserved through store/find cycle" do
      store = VectorStore.new()
      meta = %{"room" => "kitchen", "item" => "key"}
      text = "found a key in the kitchen"
      {_, store} = VectorStore.store(store, text, VectorStore.embed(text), meta)

      [result] = VectorStore.find_similar(store, VectorStore.embed("key in kitchen"), 1)

      assert result["metadata"] == meta
    end
  end

  describe "store and find_similar with dense vectors" do
    test "finds most similar vector" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "cat", [1.0, 0.0, 0.0])
      {_, store} = VectorStore.store(store, "dog", [0.9, 0.1, 0.0])
      {_, store} = VectorStore.store(store, "quantum", [0.0, 0.0, 1.0])

      [top | _] = VectorStore.find_similar(store, [0.95, 0.05, 0.0], 2)
      assert top["text"] == "cat"
    end

    test "orthogonal vectors score 0.0" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "x-axis", [1.0, 0.0, 0.0])

      [result] = VectorStore.find_similar(store, [0.0, 1.0, 0.0], 1)
      assert_in_delta result["score"], 0.0, 1.0e-10
    end
  end

  describe "collection namespacing" do
    test "store/5 tags entries with collection" do
      store = VectorStore.new()
      {1, store} = VectorStore.store(store, "spatial data", VectorStore.embed("spatial data"), %{}, "spatial")
      assert store.entries[1].collection == "spatial"
    end

    test "find_similar with collection only returns matching entries" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "the cat in the kitchen", VectorStore.embed("the cat in the kitchen"), %{}, "spatial")
      {_, store} = VectorStore.store(store, "the cat likes tuna", VectorStore.embed("the cat likes tuna"), %{}, "strategy")

      results = VectorStore.find_similar(store, VectorStore.embed("cat"), 10, "spatial")
      assert length(results) == 1
      assert hd(results)["text"] == "the cat in the kitchen"
    end

    test "find_similar without collection returns from all collections" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "observation about rooms", VectorStore.embed("observation about rooms"), %{}, "spatial")
      {_, store} = VectorStore.store(store, "observation about strategy", VectorStore.embed("observation about strategy"), %{}, "strategy")

      results = VectorStore.find_similar(store, VectorStore.embed("observation"), 10)
      assert length(results) == 2
    end

    test "different collections don't interfere with each other's rankings" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "apple pie recipe", VectorStore.embed("apple pie recipe"), %{}, "food")
      {_, store} = VectorStore.store(store, "apple crumble recipe", VectorStore.embed("apple crumble recipe"), %{}, "food")
      {_, store} = VectorStore.store(store, "apple computer history", VectorStore.embed("apple computer history"), %{}, "tech")

      food_results = VectorStore.find_similar(store, VectorStore.embed("apple pie recipe"), 10, "food")
      assert length(food_results) == 2
      assert Enum.all?(food_results, &String.contains?(&1["text"], "recipe"))
    end
  end
end
