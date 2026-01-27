defmodule RlmRecursive.Generators.Pairs do
  @moduledoc """
  Generator for OOLONG-Pairs benchmark.

  Creates a corpus of person profiles and computes all valid pairs
  (people in the same city who share at least one hobby).

  This is an O(n²) task where recursion becomes essential for large n.

  ## Example

      iex> result = RlmRecursive.Generators.Pairs.generate(profiles: 50, seed: 42)
      iex> is_list(result.ground_truth.pairs)
      true

  """

  @default_profiles 100
  @default_seed 42

  # Fewer cities to increase pair density
  @cities ["Seattle", "Portland", "Denver", "Austin", "Boston"]

  @hobbies ["hiking", "reading", "cooking", "gaming", "photography", "gardening",
            "cycling", "swimming", "painting", "yoga", "music", "fishing"]

  @doc """
  Generate an OOLONG-Pairs corpus with profiles and ground truth pairs.

  ## Options

    * `:profiles` - Number of profiles to generate (default: #{@default_profiles})
    * `:seed` - Random seed for reproducibility (default: #{@default_seed})

  ## Returns

  A map with:
    * `:corpus` - The generated corpus as a string (one profile per line)
    * `:ground_truth` - Map with `:pairs` (list of {id1, id2} tuples) and `:count`
    * `:total_profiles` - Total profiles in the corpus
    * `:query` - The pairs query
  """
  def generate(opts \\ []) do
    profiles_count = Keyword.get(opts, :profiles, @default_profiles)
    seed = Keyword.get(opts, :seed, @default_seed)

    # Seed the random number generator for reproducibility
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    # Generate profiles
    profiles = Enum.map(1..profiles_count, fn id -> generate_profile(id) end)

    # Compute ground truth pairs (O(n²) - this is what makes it hard!)
    pairs = find_all_pairs(profiles)

    # Format corpus - one profile per line as structured text
    corpus_lines =
      Enum.map(profiles, fn p ->
        hobbies_str = Enum.join(p.hobbies, ", ")
        "PROFILE #{p.id}: name=#{p.name}, city=#{p.city}, hobbies=[#{hobbies_str}]"
      end)

    %{
      corpus: Enum.join(corpus_lines, "\n"),
      ground_truth: %{
        pairs: pairs,
        count: length(pairs)
      },
      total_profiles: profiles_count,
      query: "Find all pairs of people who live in the same city AND share at least one hobby."
    }
  end

  @doc """
  Generate the question for the pairs task.
  """
  def question(_data) do
    "Find all pairs of people who live in the same city AND share at least one hobby. Return the count."
  end

  # Find all valid pairs (same city + shared hobby)
  defp find_all_pairs(profiles) do
    # Group by city first for efficiency
    by_city = Enum.group_by(profiles, & &1.city)

    # Find pairs within each city
    Enum.flat_map(by_city, fn {_city, city_profiles} ->
      find_pairs_in_group(city_profiles)
    end)
    |> Enum.sort()
  end

  # Find pairs within a group (all same city)
  defp find_pairs_in_group(profiles) do
    for p1 <- profiles,
        p2 <- profiles,
        p1.id < p2.id,
        shares_hobby?(p1, p2) do
      {p1.id, p2.id}
    end
  end

  defp shares_hobby?(p1, p2) do
    not Enum.empty?(MapSet.intersection(
      MapSet.new(p1.hobbies),
      MapSet.new(p2.hobbies)
    ))
  end

  defp generate_profile(id) do
    %{
      id: id,
      name: generate_name(),
      city: Enum.random(@cities),
      hobbies: generate_hobbies()
    }
  end

  defp generate_name do
    first_names = ["Alice", "Bob", "Carol", "David", "Emma", "Frank", "Grace", "Henry",
                   "Ivy", "Jack", "Kate", "Leo", "Maya", "Noah", "Olivia", "Peter",
                   "Quinn", "Rachel", "Sam", "Tara"]

    last_names = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
                  "Davis", "Rodriguez", "Martinez"]

    "#{Enum.random(first_names)} #{Enum.random(last_names)}"
  end

  defp generate_hobbies do
    # Each person has 2-4 hobbies (higher overlap chance)
    count = 2 + :rand.uniform(2)
    Enum.take_random(@hobbies, count)
  end
end
