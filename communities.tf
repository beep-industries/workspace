# ─────────────────────────────────────────────────────────────────────────────
# SERVICE — Communities
#
# Deux composants :
#   1. Migrations   → toujours lancées (peu importe le mode)
#                     → applique les migrations sqlx au démarrage
#   2. Service API  → uniquement si mode != "local"
#                     → construit depuis le repo cloné
#
# Les images sont buildées depuis local.repo_path (cloné par prepare_infra_files).
# Le build Rust est long (5-15 min la 1ère fois) mais les layers Docker sont
# mis en cache — les redémarrages suivants sont quasi-instantanés si le code
# n'a pas changé.
# ─────────────────────────────────────────────────────────────────────────────

# ─── Migrations ───────────────────────────────────────────────────────────────

resource "docker_image" "communities_migrations" {
  name = "${local.prefix}-communities-migrations"

  build {
    context    = local.repo_path
    dockerfile = "Dockerfile.migrations"
  }

  # Rebuild uniquement si le ref git change.
  # Note: on ne peut pas utiliser filesha1() sur local.repo_path ici car
  # le répertoire n'existe pas encore au moment du plan Terraform.
  # → Le null_resource.populate_config_volumes garantit que le repo est là à l'apply.
  triggers = {
    git_ref = local.communities_git_ref
  }

  keep_locally = false
  depends_on   = [null_resource.populate_config_volumes]
}

resource "docker_container" "communities_migrations" {
  count = data.coder_workspace.me.start_count

  image = docker_image.communities_migrations.image_id
  name  = "${local.prefix}-communities-migrations"

  # on-failure + max_retry : réessaie si la DB n'est pas encore prête
  restart         = "on-failure"
  max_retry_count = 10

  env = [
    "DATABASE_URL=postgres://communities:communities@communities-db:5432/communities",
  ]

  networks_advanced {
    name = docker_network.workspace.name
  }

  depends_on = [docker_container.communities_db]
}

# ─── Image du service Communities ─────────────────────────────────────────────
# Buildée uniquement si mode != "local"

resource "docker_image" "communities" {
  count = local.communities_managed ? 1 : 0

  name = "${local.prefix}-communities"

  build {
    context    = local.repo_path
    dockerfile = "Dockerfile"
  }

  triggers = {
    git_ref = local.communities_git_ref
  }

  keep_locally = false
  depends_on   = [null_resource.populate_config_volumes]
}

# ─── Container du service Communities ─────────────────────────────────────────
# Démarré uniquement si mode != "local" ET workspace running

resource "docker_container" "communities" {
  count = local.communities_managed ? data.coder_workspace.me.start_count : 0

  image    = docker_image.communities[0].image_id
  name     = "${local.prefix}-communities"
  hostname = "communities"

  # Redémarre jusqu'à ce que Keycloak/SpiceDB/RabbitMQ soient prêts
  restart         = "on-failure"
  max_retry_count = 5

  env = [
    # ── Base de données ──────────────────────────────────────────────────────
    "DATABASE_HOST=communities-db",
    "DATABASE_PORT=5432",
    "DATABASE_USER=communities",
    "DATABASE_PASSWORD=communities",
    "DATABASE_NAME=communities",

    # ── Sécurité / JWT ────────────────────────────────────────────────────────
    "JWT_SECRET_KEY=Key-Must-Be-at-least-32-bytes-in-length",

    # ── Keycloak ──────────────────────────────────────────────────────────────
    "KEYCLOAK_INTERNAL_URL=http://keycloak:8080",
    "KEYCLOAK_REALM=myrealm",
    "KEYCLOAK_CLIENT_ID=user-service",
    "KEYCLOAK_CLIENT_SECRET=ABvykyIUah2CcQPiRcvcgd7GA4MrEdx4",

    # ── SpiceDB ───────────────────────────────────────────────────────────────
    "SPICEDB_ENDPOINT=http://spicedb:50051",
    "SPICEDB_TOKEN=foobar",

    # ── RabbitMQ ──────────────────────────────────────────────────────────────
    "RABBIT_URI=amqp://guest:guest@rabbitmq:5672",

    # ── Autres services ───────────────────────────────────────────────────────
    "USER_SERVICE_URL=http://user-service:3001",

    # ── Config API ────────────────────────────────────────────────────────────
    "API_PORT=3003",
    "HEALTH_PORT=9090",
    "CORS_ORIGINS=http://localhost:5173,https://beep.ovh",

    # ── Observabilité ─────────────────────────────────────────────────────────
    "OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317",
    "RUST_LOG=info",
  ]

  healthcheck {
    test         = ["CMD-SHELL", "wget -qO- http://localhost:9090/health || exit 1"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 6
    start_period = "30s"
  }

  # ── Réseaux ─────────────────────────────────────────────────────────────────
  # Réseau principal (DB, Keycloak, RabbitMQ, SpiceDB)
  networks_advanced {
    name = docker_network.workspace.name
  }
  # Canal vers user-service (pour USER_SERVICE_URL)
  networks_advanced {
    name = docker_network.user_internal.name
  }
  # Canal vers authz service
  networks_advanced {
    name = docker_network.authz_communities.name
  }
  # Canal vers content service
  networks_advanced {
    name = docker_network.content_communities.name
  }

  depends_on = [
    docker_container.communities_migrations,
    docker_container.keycloak,
    docker_container.rabbitmq,
    docker_container.spicedb,
    null_resource.rabbitmq_init,
  ]
}
