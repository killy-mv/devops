output "url" {
  description = "Open this to reach the proxy"
  value       = "http://localhost:${var.proxy_port}"
}

output "apps" {
  description = "Backend containers behind the proxy"
  value       = docker_container.app[*].name
}
