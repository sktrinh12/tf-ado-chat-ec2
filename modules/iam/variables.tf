variable "hf_token" {
  description = "HuggingFace API Token"
  type        = string
  sensitive   = true
}

variable "duckdns_token" {
  description = "DuckDNS token"
  type        = string
  sensitive   = true
}
