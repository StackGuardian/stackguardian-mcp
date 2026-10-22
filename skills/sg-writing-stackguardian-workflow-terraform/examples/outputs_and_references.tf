# Passing values between workflows.
#  - At RUN time: a ${workflow::...} reference, resolved when the consumer runs.
#  - At PLAN time: the stackguardian_workflow_outputs data source (only after the producer has
#    completed an apply; it errors while the producer is inactive or has no outputs).

resource "stackguardian_workflow_group" "platform" {
  id            = "platform"
  resource_name = "platform"
}

resource "stackguardian_workflow_git" "network" {
  id                = "network"
  resource_name     = "Network"
  workflow_group_id = stackguardian_workflow_group.platform.id
  wf_type           = "TERRAFORM"

  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GITHUB_COM"
        config                  = { repo = "https://github.com/acme/network", is_private = false }
      }
    }
  }

  terraform_config = {
    terraform_version       = "1.5.7"
    managed_terraform_state = true
  }
}

resource "stackguardian_workflow_git" "app" {
  id                = "app"
  resource_name     = "App"
  workflow_group_id = stackguardian_workflow_group.platform.id
  wf_type           = "TERRAFORM"

  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GITHUB_COM"
        config                  = { repo = "https://github.com/acme/app-infra", is_private = false }
      }
    }
    iac_input_data = {
      schema_type = "RAW_JSON"
      # The whole value must be the reference; ".value" unwraps Terraform's output envelope.
      data = jsonencode({
        vpc_id = "$${workflow::${stackguardian_workflow_group.platform.id}.${stackguardian_workflow_git.network.id}.outputs.vpc_id.value}"
      })
    }
  }

  terraform_config = {
    terraform_version       = "1.5.7"
    managed_terraform_state = true
  }
}

# Plan-time read. The data source errors until "network" has completed an apply run, so gate it
# and flip the variable once that has happened.
variable "network_has_run" {
  type    = bool
  default = false
}

data "stackguardian_workflow_outputs" "network" {
  count          = var.network_has_run ? 1 : 0
  workflow_group = stackguardian_workflow_group.platform.id
  workflow       = stackguardian_workflow_git.network.id
}

output "vpc_id" {
  value = var.network_has_run ? jsondecode(data.stackguardian_workflow_outputs.network[0].data["vpc_id"]).value : null
}
