host = System.get_env("MACRINA_HOST") || "127.0.0.1"
port = String.to_integer(System.get_env("MACRINA_PORT") || "5683")

{:ok, ip} = :inet.parse_address(String.to_charlist(host))
{:ok, client} = Macrina.Client.connect(ip: ip, port: port)
{:ok, response} = Macrina.Client.get(client, "/hello")

IO.puts("Response code: #{response.code}")
IO.puts("Payload: #{response.payload}")
