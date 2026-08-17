{:ok, _apps} = Application.ensure_all_started(:inets)
ExUnit.configure(max_cases: System.schedulers_online())
ExUnit.start()
