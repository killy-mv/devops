terraform {
  required_version = ">= 1.5"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

# Talks to the local Docker daemon.
# Linux / WSL / macOS: unix:///var/run/docker.sock (the default)
# Windows (terraform.exe): npipe:////./pipe/docker_engine
provider "docker" {
  host = var.docker_host
}
