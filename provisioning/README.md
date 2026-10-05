# Provisioning

Terraform provisions the reverse-proxy setup (nginx in front of N `whoami` apps) on your local Docker. It's the same idea as `reverse-proxy/demo`, but written as **Infrastructure as Code** instead of `docker-compose.yml`.

## What is provisioning?

**Creating the infrastructure an app runs on**: servers, networks, storage, load balancers, DNS, firewall rules, accounts.

|                 | Provisioning                        | Configuration management               |
|-----------------|-------------------------------------|----------------------------------------|
| Question        | *Does the machine/network exist?*   | *What's installed and running on it?*  |
| Example         | "3 VMs in subnet X behind an LB"    | "Install nginx, copy `default.conf`"   |
| Typical tools   | Terraform, OpenTofu, Pulumi, CloudFormation | Ansible, Chef, Puppet          |

Ways to provision, from worst to best:

1. **Manual**: click through a cloud console. Slow, not repeatable, no history.
2. **Scripts**: `aws ec2 run-instances ...`. Repeatable, but you must handle "already exists", updates and deletes yourself.
3. **Infrastructure as Code (IaC)**: declare the *desired state*; the tool works out what to create, change or delete.

## Run the demo

Requirements: Terraform >= 1.5 and Docker.

> WSL: turn on *Docker Desktop → Settings → Resources → WSL integration* for your distro so `/var/run/docker.sock` exists.
> Windows `terraform.exe`: add `-var docker_host=npipe:////./pipe/docker_engine`.

```bash
cd provisioning/demo
terraform init      # download the docker provider into .terraform/
terraform plan      # preview: what would change?
terraform apply     # do it (type "yes")
```

Try it:

```bash
for i in $(seq 10); do curl -s localhost:8081 | grep Hostname; done
terraform output                 # url + app names
docker ps --filter name=tf-      # what Terraform created
terraform state list             # what Terraform is tracking
```

Clean up:

```bash
terraform destroy
```

## What's in the demo

```
demo/
├── versions.tf                    # required Terraform/provider versions + provider config
├── variables.tf                   # inputs: app_count, proxy_port, docker_host
├── main.tf                        # resources: images, network, apps, proxy
├── outputs.tf                     # values printed after apply
├── templates/default.conf.tftpl   # nginx config, generated from the app list
└── example.tfvars                 # sample variable values
```

```
                                     ┌──► tf-app-1 (traefik/whoami)
curl :8081 ──► tf-proxy (nginx) ─────┼──► tf-app-2
                                     └──► tf-app-N   (N = app_count)
               └──────────── network: tf-demo ────────────┘
```

| Compose (`reverse-proxy/demo`)       | Terraform (this demo)                                  |
|--------------------------------------|--------------------------------------------------------|
| `services: app1, app2` (copy-paste)  | `count = var.app_count` (one block, N containers)      |
| `default.conf` lists apps by hand    | `templatefile()` generates it from the same app list   |
| `docker compose up`                  | `terraform apply`                                      |
| No preview                           | `terraform plan` shows the diff before anything runs   |
| Docker only                          | Same workflow for AWS, Azure, GCP, Cloudflare, ...     |

## Walkthrough: the IaC workflow

### 1. Scale up by changing one number

```bash
terraform plan -var app_count=4
```

The plan shows:

- `docker_container.app[2]` and `app[3]` **will be created**.
- `docker_container.proxy` **must be replaced**, because its uploaded `default.conf` changed (`# forces replacement`).

```bash
terraform apply -var app_count=4
for i in $(seq 12); do curl -s localhost:8081 | grep Hostname; done   # 4 different hostnames
```

Or use a vars file: `terraform apply -var-file=example.tfvars`.

### 2. Validation catches bad input before anything is touched

```bash
terraform plan -var app_count=10    # Error: app_count must be between 1 and 5.
```

### 3. Drift: someone changes things behind Terraform's back

```bash
docker rm -f tf-app-1
terraform plan       # tf-app-1 will be created
terraform apply      # back to the desired state
```

Terraform compares **real infrastructure** against **your code**, using the state file to know which objects it owns. This is the core idea of declarative IaC: you describe *what* you want, not the steps.

### 4. Apply twice, nothing happens

```bash
terraform apply      # No changes. Your infrastructure matches the configuration.
```

That's **idempotency**. A shell script running `docker run` twice would fail with "name already in use".

## Notes and gotchas

### The state file (`terraform.tfstate`)

- It's Terraform's memory of what it created and the IDs of those objects. Lose it, and Terraform forgets it owns those containers.
- It can contain **secrets** in plain text. Never commit it (it's in `.gitignore`).
- Teams store it in a **remote backend** (S3 + lock, Terraform Cloud, ...) so everyone shares one state and two `apply`s can't run at once.

### Replace vs update in place

Some changes can be applied to a running object; others need **destroy then create**. For containers, almost everything (image, ports, uploaded files) forces replacement. Always read the plan: `~` update in place, `-/+` replace, `+` create, `-` destroy.

### `depends_on`

Terraform builds a dependency graph from references (the proxy references `docker_network.demo.id`, so the network comes first). The proxy doesn't reference the apps directly, so `depends_on` makes Terraform create the apps first. Without it, nginx can start before `app-1` exists and crash with `host not found in upstream`.

## Handy commands

```bash
terraform fmt                       # format .tf files
terraform validate                  # check syntax and references
terraform plan -out=tfplan          # save a plan...
terraform apply tfplan              # ...and apply exactly that plan
terraform show                      # everything in the state
terraform state show 'docker_container.app[0]'
terraform console                   # try expressions, e.g. [for i in range(3) : "app-${i + 1}"]
terraform apply -replace='docker_container.proxy'   # force-recreate one resource
```
