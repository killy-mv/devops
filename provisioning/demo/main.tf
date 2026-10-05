# Images: Terraform pulls them if they are missing
resource "docker_image" "nginx" {
  name = "nginx:alpine"
}

resource "docker_image" "whoami" {
  name = "traefik/whoami"
}

# Private network: apps find each other by name through Docker DNS
resource "docker_network" "demo" {
  name = "tf-demo"
}

# Backend apps: count turns one block into N containers (app-1, app-2, ...)
resource "docker_container" "app" {
  count = var.app_count

  name  = "tf-app-${count.index + 1}"
  image = docker_image.whoami.image_id

  networks_advanced {
    name    = docker_network.demo.id
    aliases = ["app-${count.index + 1}"]
  }
}

# Reverse proxy: the only container with a published port
resource "docker_container" "proxy" {
  name  = "tf-proxy"
  image = docker_image.nginx.image_id

  ports {
    internal = 80
    external = var.proxy_port
  }

  networks_advanced {
    name = docker_network.demo.id
  }

  # nginx config is generated from the app list, so it always matches app_count
  upload {
    file = "/etc/nginx/conf.d/default.conf"
    content = templatefile("${path.module}/templates/default.conf.tftpl", {
      apps = [for i in range(var.app_count) : "app-${i + 1}"]
    })
  }

  # Create the apps first, otherwise nginx fails with "host not found in upstream"
  depends_on = [docker_container.app]
}
