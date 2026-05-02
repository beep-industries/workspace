terraform {
  required_version = ">= 1.9.0"

  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.16"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.2"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
