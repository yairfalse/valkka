import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

if System.get_env("PHX_SERVER") do
  config :valkka, ValkkaWeb.Endpoint, server: true
end

if config_env() == :prod do
  # For standalone desktop mode, generate and persist a secret key base
  # in the platform-appropriate config dir so the user never needs to set an env var.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (fn ->
         config_dir = :filename.basedir(:user_config, ~c"valkka") |> to_string()
         secret_file = Path.join(config_dir, "secret_key_base")

         case File.read(secret_file) do
           {:ok, secret} ->
             String.trim(secret)

           {:error, _} ->
             secret = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)
             File.mkdir_p!(config_dir)
             File.write!(secret_file, secret)
             secret
         end
       end).()

  port = String.to_integer(System.get_env("PORT", "4420"))

  config :valkka, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :valkka, ValkkaWeb.Endpoint,
    url: [host: "localhost", port: port, scheme: "http"],
    http: [
      port: port,
      ip: {127, 0, 0, 1}
    ],
    secret_key_base: secret_key_base,
    check_origin: [
      "//localhost",
      "//127.0.0.1",
      "tauri://localhost"
    ]
end
