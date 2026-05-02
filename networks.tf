# ─────────────────────────────────────────────────────────────────────────────
# Réseaux Docker du workspace
# ─────────────────────────────────────────────────────────────────────────────
#
# Architecture réseau :
#
#   workspace_net  → réseau principal, TOUS les containers y sont connectés
#                    (infra + services + container workspace dev)
#
#   user_internal  → canal dédié communities <-> user-service
#   authz_communities → canal dédié communities <-> authz (SpiceDB listeners)
#   content_communities → canal dédié communities <-> content service
#
# Les réseaux inter-services sont créés dès maintenant même si les services
# cibles (user, authz, content) ne sont pas encore déployés. Quand ces services
# seront ajoutés au workspace, ils rejoindront simplement le bon réseau sans
# modifier la config de communities.
#
# Tous les noms sont suffixés par workspace_id pour éviter les collisions
# entre plusieurs workspaces sur le même host Docker.
# ─────────────────────────────────────────────────────────────────────────────

resource "docker_network" "workspace" {
  name   = "${local.prefix}-net"
  driver = "bridge"
}

# communities <-> user-service (quand user sera ajouté)
resource "docker_network" "user_internal" {
  name   = "user_internal-${local.workspace_id}"
  driver = "bridge"
}

# communities <-> authz service (SpiceDB listeners)
resource "docker_network" "authz_communities" {
  name   = "authz_communities-${local.workspace_id}"
  driver = "bridge"
}

# communities <-> content service
resource "docker_network" "content_communities" {
  name   = "content_communities-${local.workspace_id}"
  driver = "bridge"
}
