# GitOps: plan on every PR into main, apply (after approval) on every push to main.
# Triggers are registered by a second API call; if that fails the provider deletes the new workflow.

data "stackguardian_connector" "gitlab" {
  id = "gitlab-acme" # a GITLAB_COM connector
}

resource "stackguardian_workflow_group" "network" {
  id            = "network"
  resource_name = "network"
}

resource "stackguardian_workflow_git" "vpc" {
  id                = "vpc"
  resource_name     = "Shared VPC"
  workflow_group_id = stackguardian_workflow_group.network.id
  wf_type           = "TERRAFORM"

  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GITLAB_COM"
        config = {
          repo       = "https://gitlab.com/acme/network" # https form: webhook events are matched on this URL
          ref        = "main"
          is_private = true # triggers need a private repo + connector auth
          auth       = "/integrations/${data.stackguardian_connector.gitlab.id}"
        }
      }
    }
  }

  terraform_config = {
    terraform_version       = "1.5.7"
    managed_terraform_state = true
  }

  approvers                    = ["netops@acme.com"]
  number_of_approvals_required = 1

  vcs_triggers = {
    tracked_branch        = "main"
    push                  = { createWfRun = { enabled = true } } # push to main -> apply
    pull_request_opened   = { createWfRun = { enabled = true } } # PR into main -> plan
    pull_request_modified = { createWfRun = { enabled = true } } # new commits on that PR -> plan
    approval_pre_apply    = true                                 # push runs pause before apply
    file_triggers_enabled = true                                 # GitLab: only when these files change
    file_trigger_patterns = ["*.tf", "modules/*"]
  }
  # To stop triggering later, set every enabled = false. Removing vcs_triggers unregisters nothing.
}
