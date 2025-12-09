if System.get_env("CI") do
  Application.put_env(:stream_data, :max_runs, 300)
end

ExUnit.configure(exclude: [:e2e])
ExUnit.start()
