# Terraform workflow from a private GitHub repo, deploying to AWS through an OIDC connector,
# with SG-managed state, a 2-of-3 approval gate, a secret env var, nightly drift detection,
# error/drift emails and a private runner.

data "stackguardian_connector" "github" {
  id = "github_com" # the GITHUB_COM connector is an org singleton with this id
}

data "stackguardian_connector" "aws" {
  id = "aws-prod-oidc" # data sources fail at plan if the connector does not exist
}

data "stackguardian_runner_group" "prod" {
  id = "prod-runners"
}

resource "stackguardian_workflow_group" "payments" {
  id            = "payments"
  resource_name = "payments"
}

resource "stackguardian_workflow_group" "payments_prod" {
  id            = "${stackguardian_workflow_group.payments.id}/prod" # "payments/prod"
  resource_name = "prod"                                             # leaf display name
}

resource "stackguardian_workflow_git" "payments_api" {
  id                = "payments-api"
  resource_name     = "Payments API"
  workflow_group_id = stackguardian_workflow_group.payments_prod.id
  wf_type           = "TERRAFORM"
  description       = "Payments API infrastructure (prod)"
  tags              = ["payments", "prod"]

  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GITHUB_COM" # = the connector's kind
        config = {
          repo        = "https://github.com/acme/payments-infra"
          ref         = "main"
          working_dir = "envs/prod"
          is_private  = true
          auth        = "/integrations/${data.stackguardian_connector.github.id}"
        }
      }
    }
    iac_input_data = {
      schema_type = "RAW_JSON"
      data        = jsonencode({ region = "eu-central-1", instance_count = 3 }) # -> tfvars.json for plan
    }
  }

  deployment_platform_config = [{
    kind   = "AWS_OIDC"
    config = { integration_id = "/integrations/${data.stackguardian_connector.aws.id}" } # path form, not the bare id
  }]

  environment_variables = [
    {
      kind   = "PLAIN_TEXT"
      config = { var_name = "DB_PASSWORD", text_value = "$${secret::payments-db-pass}" } # only the reference is stored
    },
  ]

  terraform_config = {
    terraform_version       = "1.5.7" # Terraform <= 1.5.7 on managed runners
    managed_terraform_state = true    # the repo must NOT declare a backend block
    approval_pre_apply      = true    # plans with changes pause before apply
    drift_check             = true
    drift_cron              = "0 2 * * ? *" # 02:00 UTC every day (EventBridge, 6 fields)
    pre_plan_hooks = [
      # busybox sh, no tflint/jq in the image; hooks start outside the repo
      "cd \"$MOUNTED_IAC_SOURCE_CODE_DIR\" && terraform fmt -check -recursive",
    ]
  }

  approvers                    = ["alice@acme.com", "bob@acme.com", "carol@acme.com"] # lowercase
  number_of_approvals_required = 2

  mini_steps = {
    notifications = {
      email = {
        errored        = [{ recipients = ["oncall@acme.com"] }]
        drift_detected = [{ recipients = ["platform@acme.com"] }]
      }
    }
  }

  runner_constraints = {
    type  = "private"
    names = [data.stackguardian_runner_group.prod.id] # exactly one bare runner group id
  }
}
