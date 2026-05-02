# ─────────────────────────────────────────────────────────────────────────────
# Paramètres du workspace — affichés dans le formulaire de création Coder
# ─────────────────────────────────────────────────────────────────────────────

# ── Mode de déploiement de communities ───────────────────────────────────────

data "coder_parameter" "communities_mode" {
  name         = "communities_mode"
  display_name = "Communities — Mode"
  description  = <<-EOF
    Choisir comment déployer le service **Communities** dans ce workspace.

    | Mode | Comportement |
    |------|-------------|
    | 🟢 **Géré** | Cloné et déployé automatiquement depuis `main` |
    | 🔀 **Ref spécifique** | Déployé depuis la branch ou le SHA défini ci-dessous |
    | 🔧 **Local** | Pas de container — tu lances le service toi-même dans VS Code |
  EOF

  icon    = "/emojis/1f4ac.png"
  default = "managed"
  mutable = true
  order   = 1

  option {
    name        = "🟢 Géré — HEAD main"
    value       = "managed"
    description = "Déploie automatiquement depuis la branche main"
  }
  option {
    name        = "🔀 Ref spécifique"
    value       = "ref"
    description = "Utilise la branch ou le SHA défini dans le paramètre suivant"
  }
  option {
    name        = "🔧 Local — je le lance moi-même"
    value       = "local"
    description = "Aucun container — le service tourne via cargo run dans VS Code"
  }
}

# ── Ref git spécifique (branch, tag, SHA) ─────────────────────────────────────

data "coder_parameter" "communities_ref" {
  name         = "communities_ref"
  display_name = "Communities — Git ref"
  description  = <<-EOF
    Branch, tag ou SHA de commit à utiliser pour le service Communities.

    **Ignoré** si le mode est `Géré` (utilise toujours `main`) ou `Local`.

    Exemples : `feat/new-roles`, `v1.2.3`, `abc1234`
  EOF

  icon    = "/emojis/1f4ce.png"
  default = "main"
  mutable = true
  order   = 2
}
