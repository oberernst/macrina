import Config

# Macrina logs follow `[Category] short message` with all dynamic values in
# metadata. The allowlist below is what the console formatter renders for
# `mix test` / `iex -S mix` runs of this library; downstream applications keep
# their own Logger config and are unaffected.
config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [
    :peer,
    :port,
    :block,
    :size,
    :more,
    :count,
    :total_size,
    :missing,
    :have,
    :cached,
    :reply_size,
    :phase,
    :request,
    :response,
    :packet,
    :sender,
    :server,
    :state,
    :conn,
    :error,
    :result
  ]
