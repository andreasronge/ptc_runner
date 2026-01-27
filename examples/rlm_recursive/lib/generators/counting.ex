defmodule RlmRecursive.Generators.Counting do
  @moduledoc """
  Generator for OOLONG-Counting benchmark.

  Creates a corpus of person profiles with attributes (age, city, hobbies).
  The task is to count entities matching specific criteria.

  ## Example

      iex> result = RlmRecursive.Generators.Counting.generate(profiles: 100, seed: 42)
      iex> result.ground_truth.count >= 0
      true

  """

  @default_profiles 500
  @default_seed 42

  @cities ["New York", "Los Angeles", "Chicago", "Houston", "Phoenix", "Philadelphia",
           "San Antonio", "San Diego", "Dallas", "San Jose", "Austin", "Seattle",
           "Denver", "Boston", "Portland"]

  @hobbies ["hiking", "reading", "cooking", "gaming", "photography", "gardening",
            "cycling", "swimming", "painting", "yoga", "traveling", "music",
            "fishing", "woodworking", "knitting"]

  @doc """
  Generate an OOLONG-Counting corpus with person profiles.

  ## Options

    * `:profiles` - Number of profiles to generate (default: #{@default_profiles})
    * `:seed` - Random seed for reproducibility (default: #{@default_seed})
    * `:min_age` - Minimum age in query (default: 30)
    * `:hobby` - Hobby to count (default: "hiking")

  ## Returns

  A map with:
    * `:corpus` - The generated corpus as a string (one profile per line)
    * `:ground_truth` - Map with `:count`, `:criteria` keys
    * `:total_profiles` - Total profiles in the corpus
    * `:query` - The counting query
  """
  def generate(opts \\ []) do
    profiles_count = Keyword.get(opts, :profiles, @default_profiles)
    seed = Keyword.get(opts, :seed, @default_seed)
    min_age = Keyword.get(opts, :min_age, 30)
    hobby = Keyword.get(opts, :hobby, "hiking")

    # Seed the random number generator for reproducibility
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    # Generate profiles
    profiles = Enum.map(1..profiles_count, fn id -> generate_profile(id) end)

    # Count matches
    matching_count =
      Enum.count(profiles, fn p ->
        p.age > min_age and hobby in p.hobbies
      end)

    # Format corpus - one profile per line as structured text
    corpus_lines =
      Enum.map(profiles, fn p ->
        hobbies_str = Enum.join(p.hobbies, ", ")
        "PROFILE #{p.id}: name=#{p.name}, age=#{p.age}, city=#{p.city}, hobbies=[#{hobbies_str}]"
      end)

    %{
      corpus: Enum.join(corpus_lines, "\n"),
      ground_truth: %{
        count: matching_count,
        criteria: %{min_age: min_age, hobby: hobby}
      },
      total_profiles: profiles_count,
      query: "How many people are over #{min_age} AND have #{hobby} as a hobby?"
    }
  end

  @doc """
  Generate the question for the counting task.
  """
  def question(%{ground_truth: %{criteria: %{min_age: min_age, hobby: hobby}}}) do
    "How many people are over #{min_age} AND have #{hobby} as a hobby?"
  end

  defp generate_profile(id) do
    %{
      id: id,
      name: generate_name(),
      age: 18 + :rand.uniform(60),
      city: Enum.random(@cities),
      hobbies: generate_hobbies()
    }
  end

  defp generate_name do
    first_names = ["Alice", "Bob", "Carol", "David", "Emma", "Frank", "Grace", "Henry",
                   "Ivy", "Jack", "Kate", "Leo", "Maya", "Noah", "Olivia", "Peter",
                   "Quinn", "Rachel", "Sam", "Tara", "Uma", "Victor", "Wendy", "Xander",
                   "Yuki", "Zach"]

    last_names = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
                  "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez",
                  "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin"]

    "#{Enum.random(first_names)} #{Enum.random(last_names)}"
  end

  defp generate_hobbies do
    # Each person has 1-4 hobbies
    count = 1 + :rand.uniform(3)
    Enum.take_random(@hobbies, count)
  end
end
