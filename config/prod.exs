import Config

# Provider applications are admitted only after provider activity is marked.
# Keep both boot paths credential-inert even if a release starts them eagerly.
config :req_llm, load_dotenv: false
config :llm_db, load_dotenv: false

# Production environment configuration
