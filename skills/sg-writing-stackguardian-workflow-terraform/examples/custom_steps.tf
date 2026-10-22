# CUSTOM workflows built from StackGuardian's step templates:
# an Ansible playbook, a Helm release (with approval) and a CloudFormation change set.

resource "stackguardian_workflow_group" "ops" {
  id            = "ops"
  resource_name = "ops"
}

resource "stackguardian_workflow_git" "configure_servers" {
  id                = "configure-servers"
  resource_name     = "Configure servers"
  workflow_group_id = stackguardian_workflow_group.ops.id
  wf_type           = "CUSTOM" # no terraform_config on CUSTOM

  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GIT_OTHER" # self-hosted GitLab without a connector
        config = {
          repo       = "https://gitlab.example.com/ops/playbooks"
          ref        = "main"
          is_private = false
        }
      }
    }
    iac_input_data = {
      schema_type = "RAW_JSON"
      data        = jsonencode({ app_version = "1.4.2" }) # passed to the playbook as --extra-vars
    }
  }

  environment_variables = [ # workflow level: step-level env vars are never injected
    { kind = "PLAIN_TEXT", config = { var_name = "ANSIBLE_HOST_KEY_CHECKING", text_value = "False" } },
  ]

  wf_steps_config = [{
    name                = "ansible-playbook"
    wf_step_template_id = "/stackguardian/ansible:18"
    wf_step_input_data = {
      schema_type = "FORM_JSONSCHEMA"
      data = jsonencode({
        playbookPath  = "site.yml"
        ansibleAction = "run" # run | dry-run | check-diff
        inventoryType = "hosts"
        inventory     = "inventory/prod.ini"
      })
    }
  }]

  runner_constraints = { type = "shared" }
}

resource "stackguardian_workflow_git" "ingress" {
  id                = "ingress-nginx"
  resource_name     = "ingress-nginx (Helm)"
  workflow_group_id = stackguardian_workflow_group.ops.id
  wf_type           = "CUSTOM"

  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GIT_OTHER"
        config = {
          repo       = "https://github.com/acme/k8s-charts"
          is_private = false
        }
      }
    }
  }

  deployment_platform_config = [{
    kind   = "AWS_RBAC"
    config = { integration_id = "/integrations/aws-eks" }
  }]

  environment_variables = [
    { kind = "PLAIN_TEXT", config = { var_name = "K8S_CLUSTER_NAME", text_value = "prod-eks" } },
    { kind = "PLAIN_TEXT", config = { var_name = "AWS_DEFAULT_REGION", text_value = "eu-central-1" } },
  ]

  wf_steps_config = [{
    name                = "helm-upgrade"
    wf_step_template_id = "/stackguardian/kubernetes:13"
    approval            = true # pauses before this step
    wf_step_input_data = {
      schema_type = "FORM_JSONSCHEMA"
      data = jsonencode({
        cmdToExec        = "helm"
        kubectlVersion   = "1.33"
        workingNamespace = "ingress"
        helmAction       = "upgrade"
        helmReleaseName  = "ingress-nginx"
        helmChartPath    = "charts/ingress-nginx"
      })
    }
  }]

  approvers                    = ["platform@acme.com"]
  number_of_approvals_required = 1
}

resource "stackguardian_workflow_git" "cfn_bucket" {
  id                = "cfn-bucket"
  resource_name     = "Logs bucket (CloudFormation)"
  workflow_group_id = stackguardian_workflow_group.ops.id
  wf_type           = "CUSTOM"

  vcs_config = {
    iac_vcs_config = {
      custom_source = {
        source_config_dest_kind = "GIT_OTHER"
        config = {
          repo        = "https://github.com/acme/cfn-stacks"
          working_dir = "logs-bucket"
          is_private  = false
        }
      }
    }
  }

  deployment_platform_config = [{
    kind   = "AWS_RBAC"
    config = { integration_id = "/integrations/aws-eks" }
  }]

  wf_steps_config = [
    {
      name                = "create-changeset"
      wf_step_template_id = "/stackguardian/cloudformation:2"
      wf_step_input_data = {
        schema_type = "FORM_JSONSCHEMA"
        data        = jsonencode({ cfAction = "create-changeset", cfStackName = "logs-bucket", cfTemplateFile = "template.yaml" })
      }
    },
    {
      name                = "apply-changeset"
      wf_step_template_id = "/stackguardian/cloudformation:2"
      approval            = true
      wf_step_input_data = {
        schema_type = "FORM_JSONSCHEMA"
        data        = jsonencode({ cfAction = "apply-changeset", cfStackName = "logs-bucket" })
      }
    },
  ]

  approvers                    = ["platform@acme.com"]
  number_of_approvals_required = 1
}
