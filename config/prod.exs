import Config

# Provider applications are admitted only after provider activity is marked.
# Keep both boot paths credential-inert even if a release starts them eagerly.
config :req_llm, load_dotenv: false
config :llm_db, load_dotenv: false

# Packaged `ptc` writes machine-readable reports to stdout. OTP's default
# handler uses standard_io, so a TLS alert would prefix that JSON (#1583).
config :logger, :default_handler, config: [type: :standard_error]

# Production environment configuration
