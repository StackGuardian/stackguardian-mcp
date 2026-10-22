# Local-only module for the terraform-deploy evals. It touches no cloud
# account: terraform_data is built in, and local_file writes next to this file.
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

variable "greeting" {
  type        = string
  description = "Text written to hello.txt."
}

variable "slow_seconds" {
  type        = number
  default     = 0
  description = "Seconds the apply sleeps; the locked-state eval sets it to hold the lock."
}

resource "terraform_data" "release" {
  input = var.greeting

  provisioner "local-exec" {
    command = "sleep ${var.slow_seconds}"
  }
}

resource "local_file" "hello" {
  filename = "${path.module}/hello.txt"
  content  = "${var.greeting}\n"

  # Written after the sleep, so a held lock never produces hello.txt early.
  depends_on = [terraform_data.release]
}

output "file" {
  value = local_file.hello.filename
}
