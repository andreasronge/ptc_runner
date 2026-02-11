defmodule RlmRecursive.Generators.SemanticPairs do
  @moduledoc """
  Generator for semantic OOLONG-Pairs benchmark.

  Creates profiles where pair compatibility requires SEMANTIC REASONING -
  the LLM must judge if two people's interests are "compatible" based on
  understanding hobby relationships, not just exact matches.

  This forces recursion because each pair comparison needs LLM judgment.

  ## Compatibility Rules (hidden from LLM)

  Hobbies are grouped into categories:
  - outdoor: hiking, camping, fishing, birdwatching, kayaking
  - creative: painting, photography, writing, pottery, music
  - fitness: yoga, swimming, cycling, running, climbing
  - tech: gaming, coding, electronics, 3d_printing, robotics
  - social: cooking, board_games, dancing, volunteering, book_club

  Two people are "compatible" if they have hobbies in the SAME category
  or in RELATED categories (outdoor<->fitness, creative<->social).

  The LLM doesn't know these rules - it must reason semantically about
  whether two people would enjoy activities together.
  """

  @default_profiles 8
  @default_seed 42

  # Only 2 cities to maximize pairs per group (forces recursion)
  @cities ["Seattle", "Portland"]

  # Hobbies grouped by category (LLM doesn't see this mapping)
  @hobby_categories %{
    outdoor: ["hiking", "camping", "fishing", "birdwatching", "kayaking"],
    creative: ["painting", "photography", "writing", "pottery", "music"],
    fitness: ["yoga", "swimming", "cycling", "running", "climbing"],
    tech: ["gaming", "coding", "electronics", "3d_printing", "robotics"],
    social: ["cooking", "board_games", "dancing", "volunteering", "book_club"]
  }

  # Related category pairs (bidirectional)
  @related_categories [
    {:outdoor, :fitness},
    {:creative, :social},
    {:tech, :creative},
    {:fitness, :social}
  ]

  @doc """
  Generate a semantic pairs corpus requiring LLM judgment per pair.

  ## Options

    * `:profiles` - Number of profiles (default: #{@default_profiles})
    * `:seed` - Random seed (default: #{@default_seed})

  ## Returns

  Map with `:corpus`, `:ground_truth`, `:total_profiles`, `:query`
  """
  def generate(opts \\ []) do
    profiles_count = Keyword.get(opts, :profiles, @default_profiles)
    seed = Keyword.get(opts, :seed, @default_seed)

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    profiles = Enum.map(1..profiles_count, fn id -> generate_profile(id) end)
    pairs = find_compatible_pairs(profiles)

    corpus_lines =
      Enum.map(profiles, fn p ->
        interests_str = Enum.join(p.interests, ", ")
        "PROFILE #{p.id}: name=#{p.name}, city=#{p.city}, interests=[#{interests_str}]"
      end)

    %{
      corpus: Enum.join(corpus_lines, "\n"),
      ground_truth: %{
        pairs: pairs,
        count: length(pairs)
      },
      total_profiles: profiles_count,
      query: semantic_query()
    }
  end

  defp semantic_query do
    """
    Find all pairs of people in the same city who have COMPATIBLE interests.

    Compatible means their interests suggest they would enjoy activities together.
    This requires semantic judgment - not just exact hobby matches, but understanding
    if interests are related or complementary.

    Examples of compatible interests:
    - hiking + cycling (both outdoor/active)
    - painting + photography (both creative/artistic)
    - gaming + robotics (both tech-oriented)
    - cooking + board_games (both social activities)

    Examples of NON-compatible interests:
    - gaming + hiking (different worlds)
    - pottery + robotics (unrelated)
    - fishing + dancing (no connection)

    You must evaluate EACH pair semantically to determine compatibility.
    """
  end

  def question(_data) do
    "Find pairs with compatible interests (same city, semantically related hobbies). Return count."
  end

  # Find pairs where interests are in same/related categories
  defp find_compatible_pairs(profiles) do
    by_city = Enum.group_by(profiles, & &1.city)

    Enum.flat_map(by_city, fn {_city, city_profiles} ->
      for p1 <- city_profiles,
          p2 <- city_profiles,
          p1.id < p2.id,
          compatible?(p1, p2) do
        {p1.id, p2.id}
      end
    end)
    |> Enum.sort()
  end

  # Check if two profiles have compatible interests
  defp compatible?(p1, p2) do
    cats1 = get_categories(p1.interests)
    cats2 = get_categories(p2.interests)

    # Compatible if any category overlaps OR is related
    Enum.any?(cats1, fn c1 ->
      Enum.any?(cats2, fn c2 ->
        c1 == c2 or categories_related?(c1, c2)
      end)
    end)
  end

  defp get_categories(interests) do
    interests
    |> Enum.map(&hobby_to_category/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp hobby_to_category(hobby) do
    Enum.find_value(@hobby_categories, fn {category, hobbies} ->
      if hobby in hobbies, do: category
    end)
  end

  defp categories_related?(c1, c2) do
    {c1, c2} in @related_categories or {c2, c1} in @related_categories
  end

  defp generate_profile(id) do
    # Pick 2-3 interests from 1-2 categories
    num_categories = Enum.random([1, 1, 2])
    categories = Enum.take_random(Map.keys(@hobby_categories), num_categories)

    interests =
      categories
      |> Enum.flat_map(fn cat -> Enum.take_random(@hobby_categories[cat], Enum.random([1, 2])) end)
      |> Enum.uniq()
      |> Enum.take(3)

    %{
      id: id,
      name: generate_name(),
      city: Enum.random(@cities),
      interests: interests
    }
  end

  defp generate_name do
    first = Enum.random(~w[Alex Jordan Taylor Morgan Casey Riley Jamie Avery Quinn Sam])
    last = Enum.random(~w[Chen Kim Patel Singh Lee Garcia Wilson Brown Taylor Clark])
    "#{first} #{last}"
  end
end
