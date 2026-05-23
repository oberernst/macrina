import Config

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
