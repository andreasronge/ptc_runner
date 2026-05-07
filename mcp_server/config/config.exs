import Config

# Per-environment settings live in the corresponding config/<env>.exs.
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
