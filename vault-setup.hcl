# Example non-dev Vault configuration.
# The default docker-compose.yml uses `vault server -dev`, so this file is not
# mounted by default. Use it as a starting point for a persistent Vault.

storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = true
}

api_addr = "http://0.0.0.0:8200"
ui = true