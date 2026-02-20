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

  describe "cosine_similarity/2" do
    test "identical vectors have similarity 1.0" do
      vec = VectorStore.embed("hello world")
      assert_in_delta VectorStore.cosine_similarity(vec, vec), 1.0, 1.0e-10
    end

    test "orthogonal vectors have similarity 0.0" do
      vec_a = %{"aaa" => 1}
      vec_b = %{"zzz" => 1}
      assert VectorStore.cosine_similarity(vec_a, vec_b) == 0.0
    end

    test "empty vector returns 0.0" do
      assert VectorStore.cosine_similarity(%{}, %{"aaa" => 1}) == 0.0
      assert VectorStore.cosine_similarity(%{"aaa" => 1}, %{}) == 0.0
      assert VectorStore.cosine_similarity(%{}, %{}) == 0.0
    end
  end

  describe "store/3 and find_similar/3" do
    test "stores and retrieves entries" do
      store = VectorStore.new()
      {1, store} = VectorStore.store(store, "the cat sat on the mat")
      {2, store} = VectorStore.store(store, "the dog sat on the log")
      {3, store} = VectorStore.store(store, "quantum physics lecture notes")

      results = VectorStore.find_similar(store, "the cat sat on the mat", 2)

      assert length(results) == 2
      assert hd(results)["text"] == "the cat sat on the mat"
    end

    test "top-k ranking — most similar first" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "apple pie recipe")
      {_, store} = VectorStore.store(store, "apple crumble recipe")
      {_, store} = VectorStore.store(store, "quantum mechanics textbook")

      [first, second | _] = VectorStore.find_similar(store, "apple pie recipe", 3)

      assert first["score"] >= second["score"]
      assert first["text"] == "apple pie recipe"
    end

    test "empty store returns empty list" do
      store = VectorStore.new()
      assert VectorStore.find_similar(store, "anything", 5) == []
    end

    test "metadata is preserved through store/find cycle" do
      store = VectorStore.new()
      meta = %{"room" => "kitchen", "item" => "key"}
      {_, store} = VectorStore.store(store, "found a key in the kitchen", meta)

      [result] = VectorStore.find_similar(store, "key in kitchen", 1)

      assert result["metadata"] == meta
    end
  end

  describe "collection namespacing" do
    test "store/4 tags entries with collection" do
      store = VectorStore.new()
      {1, store} = VectorStore.store(store, "spatial data", %{}, "spatial")
      assert store.entries[1].collection == "spatial"
    end

    test "find_similar/4 with collection only returns matching entries" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "the cat in the kitchen", %{}, "spatial")
      {_, store} = VectorStore.store(store, "the cat likes tuna", %{}, "strategy")

      results = VectorStore.find_similar(store, "cat", 10, "spatial")
      assert length(results) == 1
      assert hd(results)["text"] == "the cat in the kitchen"
    end

    test "find_similar/3 (no collection) returns from all collections" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "observation about rooms", %{}, "spatial")
      {_, store} = VectorStore.store(store, "observation about strategy", %{}, "strategy")

      results = VectorStore.find_similar(store, "observation", 10)
      assert length(results) == 2
    end

    test "different collections don't interfere with each other's rankings" do
      store = VectorStore.new()
      {_, store} = VectorStore.store(store, "apple pie recipe", %{}, "food")
      {_, store} = VectorStore.store(store, "apple crumble recipe", %{}, "food")
      {_, store} = VectorStore.store(store, "apple computer history", %{}, "tech")

      food_results = VectorStore.find_similar(store, "apple pie recipe", 10, "food")
      assert length(food_results) == 2
      assert Enum.all?(food_results, &String.contains?(&1["text"], "recipe"))
    end
  end
end
