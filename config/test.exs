import Config

# Disable automatic .env loading by req_llm so that command-line env vars take precedence
# This allows: PTC_TEST_MODEL=deepseek-local mix test --include e2e
config :req_llm, load_dotenv: false
