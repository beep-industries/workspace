terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

# ─── Data Sources ──────────────────────────────────────────────────────────────

data "coder_provisioner"     "me" {}
data "coder_workspace"       "me" {}
data "coder_workspace_owner" "me" {}

# ─── Providers ─────────────────────────────────────────────────────────────────

provider "coder"  {}
provider "docker" {}

# ─── Locals ────────────────────────────────────────────────────────────────────

locals {
  username       = data.coder_workspace_owner.me.name
  workspace_id   = data.coder_workspace.me.id
  workspace_name = data.coder_workspace.me.name

  # Préfixe unique pour toutes les ressources Docker de ce workspace.
  # Évite les collisions si plusieurs workspaces tournent sur le même host.
  prefix = "beep-${local.workspace_id}"

  # ── Modes du service communities ─────────────────────────────────────────────
  communities_mode    = data.coder_parameter.communities_mode.value
  communities_managed = local.communities_mode != "local"

  # Résoud le ref git effectif :
  #   managed → toujours HEAD main
  #   ref     → valeur saisie par l'utilisateur
  #   local   → valeur ignorée (pas de container)
  communities_git_ref = (
    local.communities_mode == "managed"
    ? "main"
    : data.coder_parameter.communities_ref.value
  )

  # Chemin de clone sur le host Coder.
  # Utilisé comme build context pour les images Docker et comme bind mount
  # pour les fichiers de config (keycloak-config, init-uuid.sql, etc.)
  # Note: /tmp peut être vidé par l'OS. Le null_resource.prepare_infra_files
  # s'assure de re-cloner si besoin à chaque apply (always_run = timestamp()).
  repo_path = "/tmp/beep-workspace-${local.workspace_id}/communities"
}

# ─── Coder Agent ───────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  startup_script = <<-EOT
    set -e

    # ── code-server (VS Code dans le navigateur) ─────────────────────────────
    curl -fsSL https://code-server.dev/install.sh \
      | sh -s -- --method=standalone --prefix=/tmp/code-server
    /tmp/code-server/bin/code-server \
      --auth none --port 13337 \
      >/tmp/code-server.log 2>&1 &

    # ── Rust toolchain ────────────────────────────────────────────────────────
    if ! command -v rustup &>/dev/null; then
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable
    fi
    source "$HOME/.cargo/env"

    # ── sqlx-cli (pour lancer les migrations manuellement) ────────────────────
    if ! command -v sqlx &>/dev/null; then
      cargo install sqlx-cli --no-default-features --features postgres
    fi

    # ── Clone du repo si mode local (dev dans VS Code) ────────────────────────
    if [ ! -d "$HOME/communities" ]; then
      git clone --branch "${local.communities_git_ref}" \
        https://github.com/beep-industries/communities.git \
        "$HOME/communities"
    fi

    # ── Redirection de ports vers les services Docker ─────────────────────────
    # Le Coder agent proxy les URL http://localhost:PORT depuis ce container.
    # socat redirige ces ports vers les hostnames Docker sur le réseau partagé.
    if ! command -v socat &>/dev/null; then
      sudo apt-get install -y socat -qq
    fi

    # Infra toujours disponible
    socat TCP-LISTEN:8080,fork,reuseaddr TCP:keycloak:8080   >/dev/null 2>&1 &
    socat TCP-LISTEN:15672,fork,reuseaddr TCP:rabbitmq:15672 >/dev/null 2>&1 &
    socat TCP-LISTEN:5432,fork,reuseaddr TCP:communities-db:5432 >/dev/null 2>&1 &

    # Communities API uniquement si le service est géré (pas local)
    COMMUNITIES_MODE="${local.communities_mode}"
    if [ "$COMMUNITIES_MODE" != "local" ]; then
      socat TCP-LISTEN:3003,fork,reuseaddr TCP:communities:3003 >/dev/null 2>&1 &
      socat TCP-LISTEN:9090,fork,reuseaddr TCP:communities:9090 >/dev/null 2>&1 &
    fi

    echo "✅ Workspace Beep prêt"
    echo "   → communities cloné dans ~/communities"
    echo "   → DB:       postgres://communities:communities@localhost:5432/communities"
    echo "   → Keycloak: http://localhost:8080/admin  (admin/admin)"
    echo "   → RabbitMQ: http://localhost:15672        (guest/guest)"
  EOT

  # Variables d'environnement injectées dans le shell du développeur.
  # Permettent de lancer `cargo run` sans argument quand mode = local.
  env = {
    # Git identity
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email

    # Connexion à la DB communities (via socat sur localhost)
    DATABASE_HOST     = "localhost"
    DATABASE_PORT     = "5432"
    DATABASE_USER     = "communities"
    DATABASE_PASSWORD = "communities"
    DATABASE_NAME     = "communities"
    DATABASE_URL      = "postgres://communities:communities@localhost:5432/communities"

    # Services (via hostnames Docker depuis le workspace container)
    KEYCLOAK_INTERNAL_URL = "http://keycloak:8080"
    KEYCLOAK_REALM        = "myrealm"
    SPICEDB_ENDPOINT      = "http://spicedb:50051"
    SPICEDB_TOKEN         = "foobar"
    RABBIT_URI            = "amqp://guest:guest@rabbitmq:5672"
    USER_SERVICE_URL      = "http://user-service:3001"

    # Config communities
    JWT_SECRET_KEY = "Key-Must-Be-at-least-32-bytes-in-length"
    API_PORT       = "3003"
    HEALTH_PORT    = "9090"
    CORS_ORIGINS   = "http://localhost:5173,https://beep.ovh"
    RUST_LOG       = "debug"
    SQLX_OFFLINE   = "false"
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

# ─── Coder Apps ────────────────────────────────────────────────────────────────

resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code"
  url          = "http://localhost:13337/?folder=/home/${local.username}/communities"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 6
  }
}

# API Communities — visible seulement si le service est géré
resource "coder_app" "communities_api" {
  count        = local.communities_managed ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "communities"
  display_name = "Communities API"
  url          = "http://localhost:3003"
  icon         = "/emojis/1f4ac.png"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:9090/health"
    interval  = 10
    threshold = 6
  }
}

resource "coder_app" "keycloak_admin" {
  agent_id     = coder_agent.main.id
  slug         = "keycloak"
  display_name = "Keycloak"
  url          = "http://localhost:8080/admin"
  icon         = "/emojis/1f511.png"
  subdomain    = false
  share        = "owner"
}

resource "coder_app" "rabbitmq_mgmt" {
  agent_id     = coder_agent.main.id
  slug         = "rabbitmq"
  display_name = "RabbitMQ"
  url          = "http://localhost:15672"
  icon         = "/emojis/1f430.png"
  subdomain    = false
  share        = "owner"
}

resource "coder_app" "zed" {
    agent_id = coder_agent.main.id
    slug          = "slug"
    display_name  = "Zed"
    external = true
    url      = "zed://ssh/coder.${data.coder_workspace.me.name}"
    icon     = "/icon/zed.svg"
}


# ─── Container workspace (dev) ─────────────────────────────────────────────────

resource "docker_volume" "home" {
  name = "${local.prefix}-home"
  lifecycle { ignore_changes = all }
}

resource "docker_image" "workspace" {
  name = "${local.prefix}-workspace"
  build {
    context = "./build"
    build_args = {
      USER = local.username
    }
  }
  # Rebuild si le Dockerfile change
  triggers = {
    dockerfile_hash = sha1(join("", [for f in fileset(path.module, "build/*") : filesha1(f)]))
  }
}

resource "docker_container" "workspace" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.workspace.image_id
  name     = "${local.prefix}-workspace"
  hostname = local.workspace_name

  entrypoint = ["sh", "-c", replace(
    coder_agent.main.init_script,
    "/localhost|127\\.0\\.0\\.1/",
    "host.docker.internal"
  )]

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
  ]

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  volumes {
    container_path = "/home/${local.username}"
    volume_name    = docker_volume.home.name
    read_only      = false
  }

  # Le workspace est sur le réseau principal pour accéder à tous les services
  # via leurs hostnames (communities-db, keycloak, rabbitmq, spicedb...)
  networks_advanced {
    name = docker_network.workspace.name
  }
}
