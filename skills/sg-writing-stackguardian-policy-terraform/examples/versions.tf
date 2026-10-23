terraform {
  required_version = ">= 1.5"

  required_providers {
    stackguardian = {
      # Full address so the same code works under OpenTofu (its registry has no copy).
      source  = "registry.terraform.io/StackGuardian/stackguardian"
      version = "~> 1.12.3"
    }
  }
}

# Credentials from the environment:
#   STACKGUARDIAN_API_KEY   raw key (sgu_/sgo_...), no "apikey " prefix
#   STACKGUARDIAN_ORG_NAME  org slug
#   STACKGUARDIAN_API_URI   https://api.app.stackguardian.io (EU) or https://api.us.stackguardian.io (US) — there is no default
provider "stackguardian" {}
