variable "docker_host" {
  description = "Docker daemon to provision on"
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "app_count" {
  description = "How many backend apps to run behind the proxy"
  type        = number
  default     = 2

  validation {
    condition     = var.app_count >= 1 && var.app_count <= 5
    error_message = "app_count must be between 1 and 5."
  }
}

variable "proxy_port" {
  description = "Port on your machine that reaches the proxy"
  type        = number
  default     = 8081
}
