# ─────────────────────────────────────────────────────────────────────────────
# INFRASTRUCTURE — PostgreSQL · Keycloak · RabbitMQ · SpiceDB
# ─────────────────────────────────────────────────────────────────────────────

# ─── Peuplement des volumes de configuration ──────────────────────────────────
#
# Les fichiers de config (init-uuid.sql, keycloak-config/, rabbitmq-init.sh)
# sont copiés depuis le repo communities dans des volumes Docker nommés.
# Contrairement aux bind-mounts depuis /tmp, les volumes Docker sont persistants
# et ne risquent pas d'être vidés par l'OS entre deux démarrages du workspace.
#
# Le null_resource clone le repo si nécessaire, puis copie les fichiers dans
# les volumes via `docker run alpine`. Idempotent : toujours_run force le
# re-check à chaque apply, mais le script ne reclone que si le répertoire
# est absent.
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_volume" "postgres_init" {
  name = "${local.prefix}-postgres-init"
  lifecycle { ignore_changes = all }
}

resource "docker_volume" "keycloak_config" {
  name = "${local.prefix}-keycloak-config"
  lifecycle { ignore_changes = all }
}

resource "docker_volume" "infra_scripts" {
  name = "${local.prefix}-infra-scripts"
  lifecycle { ignore_changes = all }
}

resource "null_resource" "populate_config_volumes" {
  triggers = {
    always_run = timestamp()
    git_ref    = local.communities_git_ref
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REPO="${local.repo_path}"

      if [ ! -d "$REPO" ] || [ ! -f "$REPO/Dockerfile" ]; then
        echo "Cloning communities @ ${local.communities_git_ref}..."
        rm -rf "$REPO"
        mkdir -p "$(dirname $REPO)"
        git clone --depth 1 \
          --branch "${local.communities_git_ref}" \
          https://github.com/beep-industries/communities.git \
          "$REPO"
        echo "Clone terminé"
      else
        echo "Repo déjà présent, skip clone"
      fi

      docker run --rm \
        -v "${local.prefix}-postgres-init:/pg-init" \
        -v "${local.prefix}-keycloak-config:/kc-config" \
        -v "${local.prefix}-infra-scripts:/scripts" \
        -v "$REPO:/src:ro" \
        alpine sh -c "
          cp /src/compose/init-uuid.sql /pg-init/
          cp -r /src/keycloak-config/. /kc-config/
          cp /src/compose/rabbitmq-init.sh /scripts/
          chmod +x /scripts/rabbitmq-init.sh
        "
    EOT
  }
}

# ─── Volumes persistants ───────────────────────────────────────────────────────

resource "docker_volume" "communities_db" {
  name = "${local.prefix}-communities-db"
  lifecycle { ignore_changes = all }
}

resource "docker_volume" "keycloak_db" {
  name = "${local.prefix}-keycloak-db"
  lifecycle { ignore_changes = all }
}

resource "docker_volume" "rabbitmq_data" {
  name = "${local.prefix}-rabbitmq"
  lifecycle { ignore_changes = all }
}

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL — Base de données du service Communities
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "postgres" {
  name         = "postgres:17"
  keep_locally = true
}

resource "docker_container" "communities_db" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.postgres.image_id
  name     = "${local.prefix}-communities-db"
  hostname = "communities-db"
  restart  = "unless-stopped"

  env = [
    "POSTGRES_DB=communities",
    "POSTGRES_USER=communities",
    "POSTGRES_PASSWORD=communities",
  ]

  volumes {
    volume_name    = docker_volume.communities_db.name
    container_path = "/var/lib/postgresql/data"
  }

  # init-uuid.sql active pgcrypto — Postgres ne l'exécute qu'à la première init de la DB.
  volumes {
    volume_name    = docker_volume.postgres_init.name
    container_path = "/docker-entrypoint-initdb.d"
  }

  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -U communities -d communities"]
    interval     = "5s"
    timeout      = "5s"
    retries      = 10
    start_period = "10s"
  }

  networks_advanced {
    name = docker_network.workspace.name
  }

  depends_on = [null_resource.populate_config_volumes]
}

# ─────────────────────────────────────────────────────────────────────────────
# Keycloak — Identity & Access Management
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "postgres_keycloak" {
  name         = "postgres:17"
  keep_locally = true
}

resource "docker_container" "keycloak_db" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.postgres_keycloak.image_id
  name     = "${local.prefix}-keycloak-db"
  hostname = "keycloak-db"
  restart  = "unless-stopped"

  env = [
    "POSTGRES_DB=keycloak",
    "POSTGRES_USER=keycloak",
    "POSTGRES_PASSWORD=keycloak",
  ]

  volumes {
    volume_name    = docker_volume.keycloak_db.name
    container_path = "/var/lib/postgresql/data"
  }

  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -U keycloak -d keycloak"]
    interval     = "5s"
    timeout      = "5s"
    retries      = 10
    start_period = "10s"
  }

  networks_advanced {
    name = docker_network.workspace.name
  }
}

resource "docker_image" "keycloak" {
  name         = "quay.io/keycloak/keycloak:26.4.2"
  keep_locally = true
}

resource "docker_container" "keycloak" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.keycloak.image_id
  name     = "${local.prefix}-keycloak"
  hostname = "keycloak"
  restart  = "unless-stopped"

  command = ["start", "--import-realm"]

  env = [
    "KC_HOSTNAME=localhost",
    "KC_HTTP_ENABLED=true",
    "KC_HOSTNAME_STRICT_HTTPS=false",
    "KC_HEALTH_ENABLED=true",
    "KC_DB=postgres",
    "KC_DB_URL=jdbc:postgresql://keycloak-db/keycloak",
    "KC_DB_USERNAME=keycloak",
    "KC_DB_PASSWORD=keycloak",
    "KEYCLOAK_ADMIN=admin",
    "KEYCLOAK_ADMIN_PASSWORD=admin",
  ]

  # Realm importé depuis le volume persistant (plus de bind-mount /tmp)
  volumes {
    volume_name    = docker_volume.keycloak_config.name
    container_path = "/opt/keycloak/data/import"
  }

  healthcheck {
    # L'image Keycloak (UBI minimal) ne contient pas curl — on utilise bash TCP
    # pour tester le port management (9000) exposé depuis Keycloak 25+.
    test         = ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/9000 && printf 'GET /health/ready HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q 'status.*UP' <&3 || exit 1"]
    interval     = "15s"
    timeout      = "10s"
    retries      = 10
    start_period = "60s"
  }

  networks_advanced {
    name = docker_network.workspace.name
  }

  depends_on = [
    docker_container.keycloak_db,
    null_resource.populate_config_volumes,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# RabbitMQ — Message Broker
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "rabbitmq" {
  name         = "rabbitmq:3-management"
  keep_locally = true
}

resource "docker_container" "rabbitmq" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.rabbitmq.image_id
  name     = "${local.prefix}-rabbitmq"
  hostname = "rabbitmq"
  restart  = "unless-stopped"

  env = [
    "RABBITMQ_DEFAULT_USER=guest",
    "RABBITMQ_DEFAULT_PASS=guest",
  ]

  volumes {
    volume_name    = docker_volume.rabbitmq_data.name
    container_path = "/var/lib/rabbitmq"
  }

  healthcheck {
    test         = ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 10
    start_period = "20s"
  }

  networks_advanced {
    name = docker_network.workspace.name
  }

  networks_advanced {
    name = docker_network.authz_communities.name
  }
}

resource "null_resource" "rabbitmq_init" {
  count = data.coder_workspace.me.start_count

  triggers = {
    always_run   = timestamp()
    workspace_id = local.workspace_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      docker run --rm \
        --network "${docker_network.workspace.name}" \
        -v "${local.prefix}-infra-scripts:/scripts:ro" \
        --env RABBITMQ_HOST=rabbitmq \
        --env RABBITMQ_USER=guest \
        --env RABBITMQ_PASS=guest \
        rabbitmq:3-management \
        bash -c "
          echo 'Attente de RabbitMQ...'
          for i in \$(seq 1 30); do
            curl -sf -u guest:guest http://rabbitmq:15672/api/overview \
              > /dev/null 2>&1 && break
            sleep 5
          done
          echo 'RabbitMQ prêt, lancement du script d init...'
          bash /scripts/rabbitmq-init.sh
        "
    EOT
  }

  depends_on = [
    docker_container.rabbitmq,
    null_resource.populate_config_volumes,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# SpiceDB — Fine-grained Authorization (ReBAC)
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_image" "spicedb" {
  name         = "authzed/spicedb:latest"
  keep_locally = true
}

resource "docker_container" "spicedb" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.spicedb.image_id
  name     = "${local.prefix}-spicedb"
  hostname = "spicedb"
  restart  = "unless-stopped"

  command = [
    "serve",
    "--grpc-preshared-key=foobar",
    "--datastore-engine=memory",
    "--http-enabled=true",
  ]

  networks_advanced {
    name = docker_network.workspace.name
  }

  networks_advanced {
    name = docker_network.authz_communities.name
  }
}
