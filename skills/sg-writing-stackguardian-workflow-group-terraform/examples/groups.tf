# A small group hierarchy, a workflow inside it, and how policies / lookups address groups.

resource "stackguardian_workflow_group" "platform" {
  id            = "platform"
  resource_name = "Platform"
  description   = "Shared platform infrastructure"
  tags          = ["platform"]
}

resource "stackguardian_workflow_group" "networking" {
  id            = "${stackguardian_workflow_group.platform.id}/networking" # -> "platform/networking"
  resource_name = "Networking"
  description   = "VPCs, DNS, transit"
}

resource "stackguardian_workflow_group" "security" {
  id            = "${stackguardian_workflow_group.platform.id}/security"
  resource_name = "Security"
  description   = "Guardrail tooling"
  # no tags: omit the attribute — tags = [] on a group ends in "inconsistent result"
}

resource "stackguardian_workflow_git" "dns" {
  id                = "dns"
  resource_name     = "DNS zones"
  workflow_group_id = stackguardian_workflow_group.networking.id # bare id, full nested path

  wf_type = "TERRAFORM"
  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GITHUB_COM"
        config                  = { repo = "https://github.com/acme/dns", is_private = false }
      }
    }
  }
  terraform_config = {
    terraform_version       = "1.5.7"
    managed_terraform_state = true
  }
}

# A group created elsewhere (dashboard ids often carry a random suffix): look it up by id.
# data "stackguardian_workflow_group" "legacy" { id = "gitops-y8pf2mb1" }

output "policy_scope_for_platform" {
  description = "enforced_on form: covers platform, its nested groups and all workflows below"
  value       = "/wfgrps/${stackguardian_workflow_group.platform.id}"
}

output "chaining_group_id" {
  description = "wf_chaining / workflow_group_id / runtime-reference form: the bare id"
  value       = stackguardian_workflow_group.networking.id
}
