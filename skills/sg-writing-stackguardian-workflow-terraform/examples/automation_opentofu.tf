# OpenTofu workflow from a public repo with a weekday schedule, a completion webhook,
# error email, and a chained follow-up workflow that runs after every successful run.

resource "stackguardian_workflow_group" "web" {
  id            = "web"
  resource_name = "web"
}

resource "stackguardian_workflow_git" "cdn_invalidate" {
  id                = "cdn-invalidate"
  resource_name     = "CDN invalidation"
  workflow_group_id = stackguardian_workflow_group.web.id
  wf_type           = "CUSTOM"

  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GIT_OTHER"
        config = {
          repo       = "https://github.com/acme/web-scripts"
          is_private = false # public repo: no auth needed
        }
      }
    }
  }

  deployment_platform_config = [{
    kind   = "AWS_RBAC"
    config = { integration_id = "/integrations/aws-web" }
  }]

  wf_steps_config = [{
    name                = "invalidate"
    wf_step_template_id = "/stackguardian/sg-common-utils:1" # cloud CLIs + shell utils
    cmd_override        = "aws cloudfront create-invalidation --distribution-id E123EXAMPLE --paths '/*'"
  }]

  # cmd_override is a plain string: private runners accept it; on shared runners it becomes the
  # ECS container command, which expects a list.
  runner_constraints = { type = "private", names = ["prod-runners"] }
}

resource "stackguardian_workflow_git" "site" {
  id                = "static-site"
  resource_name     = "Static site"
  workflow_group_id = stackguardian_workflow_group.web.id
  wf_type           = "OPENTOFU"

  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GITHUB_COM"
        config = {
          repo        = "https://github.com/acme/static-site"
          working_dir = "infra"
          is_private  = false
        }
      }
    }
    iac_input_data = {
      schema_type = "RAW_JSON"
      data        = jsonencode({ bucket_name = "acme-site", region = "eu-west-1" })
    }
  }

  terraform_config = {
    terraform_version       = "1.11.x" # OpenTofu: any >= 1.6; ".x" = newest patch
    managed_terraform_state = true
    approval_pre_apply      = false
  }

  # Each tick is a full, unattended apply (the provider cannot attach plan-only run inputs) —
  # acceptable for this static site; on prod infrastructure set approval_pre_apply = true.
  user_schedules = [{
    cron  = "0 8 ? * MON-FRI *" # 08:00 UTC Mon-Fri
    state = "ENABLED"
    desc  = "weekday refresh"
  }]

  mini_steps = {
    notifications = {
      email = { errored = [{ recipients = ["web-team@acme.com"] }] } # completed/cancelled emails are never sent
    }
    webhooks = {
      completed = [{
        webhook_name   = "deploy-done"
        webhook_url    = "https://hooks.acme.com/stackguardian"
        webhook_secret = "$${secret::sg-webhook-hmac}" # HMAC key; never inline (returned unmasked)
      }]
    }
    wf_chaining = {
      completed = [{
        workflow_group_id = stackguardian_workflow_group.web.id          # bare ids
        workflow_id       = stackguardian_workflow_git.cdn_invalidate.id # reference it so it exists first
      }]
    }
  }
}
