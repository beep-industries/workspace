# ─────────────────────────────────────────────────────────────────────────────
# INFRASTRUCTURE — PostgreSQL · Keycloak · RabbitMQ · SpiceDB
# ─────────────────────────────────────────────────────────────────────────────

# ─── Préparation des fichiers de configuration ─────────────────────────────────
#
# Plusieurs containers infra ont besoin de fichiers issus du repo communities :
#   - PostgreSQL  : compose/init-uuid.sql  (active l'extension pgcrypto)
#   - Keycloak    : keycloak-config/       (import du realm au démarrage)
#   - RabbitMQ    : compose/rabbitmq-init.sh (création des exchanges/queues)
#
# Ce null_resource clone le repo communities sur le host Coder une seule fois.
# Il utilise `always_run = timestamp()` pour s'assurer que le clone existe
# même si /tmp a été vidé entre deux démarrages du workspace. Le script est
# idempotent : il ne reclone que si le répertoire est absent.
#
# Prérequis : `git` doit être disponible sur le host Coder.
# (C'est garanti sur tout serveur Linux standard.)
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "prepare_infra_files" {
  triggers = {
    # Force le re-check à chaque apply pour garantir que les fichiers existent.
    # Le script est idempotent donc si le répertoire est déjà là, c'est un no-op.
    always_run   = timestamp()
    workspace_id = local.workspace_id
    git_ref      = local.communities_git_ref
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REPO_PATH="${local.repo_path}"

      # Re-clone si absent (ex: /tmp nettoyé par l'OS entre deux démarrages)
      if [ ! -d "$REPO_PATH" ] || [ ! -f "$REPO_PATH/Dockerfile" ]; then
        echo "Cloning communities @ ${local.communities_git_ref}..."
        rm -rf "$REPO_PATH"
        mkdir -p "$(dirname $REPO_PATH)"
        git clone --depth 1 \
          --branch "${local.communities_git_ref}" \
          https://github.com/beep-industries/communities.git \
          "$REPO_PATH"
        echo "✅ Clone terminé"
      else
        echo "ℹ️  Repo déjà présent, skip clone"
      fi
    EOT
  }
}

# ─── Volumes persistants ───────────────────────────────────────────────────────
# ignore_changes = all : protège les volumes contre la suppression si les
# attributs changent. Les données sont préservées entre start/stop du workspace.

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
  keep_locally = true # Évite de re-télécharger à chaque workspace
}

resource "docker_container" "communities_db" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.postgres.image_id
  name     = "${local.prefix}-communities-db"
  hostname = "communities-db" # Hostname DNS utilisé par les autres containers
  restart  = "unless-stopped"

  env = [
    "POSTGRES_DB=communities",
    "POSTGRES_USER=communities",
    "POSTGRES_PASSWORD=communities",
  ]

  # Données persistantes — survit au stop/start du workspace
  volumes {
    volume_name    = docker_volume.communities_db.name
    container_path = "/var/lib/postgresql/data"
  }

  # Script d'init executé par Postgres uniquement à la première initialisation
  # de la DB. Active l'extension pgcrypto nécessaire pour les UUIDs.
  volumes {
    host_path      = "${local.repo_path}/compose/init-uuid.sql"
    container_path = "/docker-entrypoint-initdb.d/01-init-uuid.sql"
    read_only      = true
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

  depends_on = [null_resource.prepare_infra_files]
}

# ─────────────────────────────────────────────────────────────────────────────
# Keycloak — Identity & Access Management
#
# Communities valide les JWTs via Keycloak (OIDC) ET via JWT_SECRET_KEY.
# Le realm "myrealm" est importé depuis keycloak-config/ au démarrage de
# Keycloak grâce à la commande `start --import-realm`.
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

  # --import-realm : Keycloak importe les fichiers JSON du volume au démarrage.
  # Si le realm existe déjà en DB, l'import est ignoré (idempotent).
  command = ["start", "--import-realm"]

  env = [
    "KC_HOSTNAME=localhost",
    "KC_HTTP_ENABLED=true",
    "KC_HOSTNAME_STRICT_HTTPS=false",
    "KC_HEALTH_ENABLED=true",
    # Connexion à la DB Keycloak
    "KC_DB=postgres",
    "KC_DB_URL=jdbc:postgresql://keycloak-db/keycloak",
    "KC_DB_USERNAME=keycloak",
    "KC_DB_PASSWORD=keycloak",
    # Admin par défaut
    "KEYCLOAK_ADMIN=admin",
    "KEYCLOAK_ADMIN_PASSWORD=admin",
  ]

  # Fichiers du realm importés depuis le repo communities cloné
  volumes {
    host_path      = "${local.repo_path}/keycloak-config"
    container_path = "/opt/keycloak/data/import"
    read_only      = true
  }

  healthcheck {
    # Keycloak 26.x expose un endpoint de santé sur le port management (9000)
    test         = ["CMD-SHELL", "curl -sf http://localhost:9000/health/ready || exit 1"]
    interval     = "15s"
    timeout      = "10s"
    retries      = 10
    start_period = "60s" # Keycloak est lent à démarrer
  }

  networks_advanced {
    name = docker_network.workspace.name
  }

  depends_on = [
    docker_container.keycloak_db,
    null_resource.prepare_infra_files,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# RabbitMQ — Message Broker
#
# Communities publie des events (outbox pattern) via RabbitMQ.
# Le script rabbitmq-init.sh crée les exchanges et queues nécessaires.
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

# Initialise les exchanges et queues dans RabbitMQ via le script du repo.
# Lance un container temporaire sur le réseau du workspace qui :
#   1. Attend que RabbitMQ soit prêt via son API management (avec retry)
#   2. Exécute le script d'init (rabbitmqadmin ou API HTTP)
resource "null_resource" "rabbitmq_init" {
  count = data.coder_workspace.me.start_count

  triggers = {
    # always_run garantit l'exécution à chaque démarrage du workspace.
    # On n'utilise pas docker_container.rabbitmq[0].name car ce container
    # n'existe pas quand start_count = 0 (workspace arrêté).
    always_run   = timestamp()
    workspace_id = local.workspace_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      docker run --rm \
        --network "${docker_network.workspace.name}" \
        --volume "${local.repo_path}/compose/rabbitmq-init.sh:/rabbitmq-init.sh:ro" \
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
          bash /rabbitmq-init.sh
        "
    EOT
  }

  depends_on = [
    docker_container.rabbitmq,
    null_resource.prepare_infra_files,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# SpiceDB — Fine-grained Authorization (ReBAC)
#
# Communities appelle SpiceDB pour vérifier les permissions (SPICEDB_ENDPOINT).
# En mode dev, on utilise le datastore en mémoire : pas de persistance,
# démarrage instantané, aucune dépendance externe.
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
    "--grpc-preshared-key=foobar",   # Token attendu par communities (SPICEDB_TOKEN)
    "--datastore-engine=memory",     # Dev uniquement — pas de persistance
    "--http-enabled=true",
  ]

  networks_advanced {
    name = docker_network.workspace.name
  }

  networks_advanced {
    name = docker_network.authz_communities.name
  }
}
