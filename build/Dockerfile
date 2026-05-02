# ─────────────────────────────────────────────────────────────────────────────
# Dockerfile du container workspace Coder
#
# Ce container est l'environnement de développement — il NE contient PAS
# le service Communities lui-même (qui est dans son propre container).
#
# Contenu :
#   - Outils système pour compiler du Rust (build-essential, libssl-dev, etc.)
#   - git, curl, socat, vim, jq
#   - Utilisateur non-root configuré par Coder (ARG USER)
#
# Le toolchain Rust (rustup), sqlx-cli et code-server sont installés par le
# startup_script de l'agent Coder — ils bénéficient ainsi du cache du volume
# home persistant (/home/${USER}) et n'allongent pas le build de cette image.
# ─────────────────────────────────────────────────────────────────────────────

FROM debian:bookworm-slim

ARG USER
ARG DEBIAN_FRONTEND=noninteractive

# ── Dépendances système ───────────────────────────────────────────────────────
# - build-essential, pkg-config, libssl-dev : compilation Rust (openssl-sys)
# - protobuf-compiler                        : génération de code gRPC
# - socat                                    : port forwarding vers les services Docker
# - postgresql-client                        : psql pour debugger la DB directement
# - jq, vim, htop                            : outils courants
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      build-essential \
      pkg-config \
      libssl-dev \
      protobuf-compiler \
      socat \
      sudo \
      vim \
      jq \
      htop \
      postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# ── Utilisateur ───────────────────────────────────────────────────────────────
# Coder injecte le nom d'utilisateur via ARG USER.
# sudo sans mot de passe est nécessaire pour installer des paquets depuis le
# startup_script (ex: code-server via le script d'install officiel).
RUN useradd -m -s /bin/bash "${USER}" \
    && echo "${USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER} \
    && chmod 0440 /etc/sudoers.d/${USER}

USER ${USER}
WORKDIR /home/${USER}
