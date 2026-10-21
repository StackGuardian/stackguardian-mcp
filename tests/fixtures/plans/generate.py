"""Writes the synthetic `terraform show -json` fixtures for terraform-plan-review.

Shapes follow a real Terraform 1.14 plan (format_version 1.2). Every account ID,
name and value is fake.

Usage: python tests/fixtures/plans/generate.py tests/fixtures/plans
"""

import json
import sys
from pathlib import Path

OUT = Path(sys.argv[1])
ACCOUNT = "123456789012"
AWS = "registry.terraform.io/hashicorp/aws"


def rc(address, rtype, name, actions, before, after, *, reason=None,
       replace_paths=None, before_sensitive=None, after_sensitive=None):
    change = {
        "actions": actions,
        "before": before,
        "after": after,
        "after_unknown": {},
        "before_sensitive": before_sensitive if before_sensitive is not None else ({} if before is not None else False),
        "after_sensitive": after_sensitive if after_sensitive is not None else ({} if after is not None else False),
    }
    if replace_paths:
        change["replace_paths"] = replace_paths
    entry = {
        "address": address,
        "mode": "managed",
        "type": rtype,
        "name": name,
        "provider_name": AWS,
        "change": change,
    }
    if reason:
        entry["action_reason"] = reason
    return entry


def plan(resource_changes, output_changes=None):
    planned = [
        {
            "address": r["address"],
            "mode": "managed",
            "type": r["type"],
            "name": r["name"],
            "provider_name": AWS,
            "schema_version": 0,
            "values": r["change"]["after"],
            "sensitive_values": r["change"]["after_sensitive"] or {},
        }
        for r in resource_changes
        if r["change"]["after"] is not None
    ]
    return {
        "format_version": "1.2",
        "terraform_version": "1.14.0",
        "planned_values": {"root_module": {"resources": planned}},
        "resource_changes": resource_changes,
        "output_changes": output_changes or {},
        "configuration": {
            "provider_config": {"aws": {"name": "aws", "full_name": AWS}},
            "root_module": {},
        },
        "timestamp": "2026-10-21T12:00:00Z",
        "applyable": True,
        "complete": True,
        "errored": False,
    }


bucket = {"bucket": "example-logs-bucket", "force_destroy": False, "tags": {"env": "dev"}}
role = {"name": "example-app-role", "assume_role_policy": "{}", "tags": {"env": "dev"}}
web_before = {"ami": "ami-0123456789abcdef0", "instance_type": "t3.small", "tags": {"env": "dev", "owner": "team-a"}}
web_after = {**web_before, "instance_type": "t3.medium", "tags": {"env": "dev", "owner": "team-b"}}
db = {
    "identifier": "example-db",
    "engine": "postgres",
    "engine_version": "16.4",
    "instance_class": "db.t3.medium",
    "allocated_storage": 50,
    "storage_encrypted": False,
    "kms_key_id": "",
    "username": "app",
    "password": "FAKE-SENSITIVE-PASSWORD-0001",
    "arn": f"arn:aws:rds:eu-central-1:{ACCOUNT}:db:example-db",
}
db_sensitive = {"password": True}

fixtures = {
    "create-only.json": plan([
        rc("aws_s3_bucket.logs", "aws_s3_bucket", "logs", ["create"], None, bucket),
        rc("aws_iam_role.app", "aws_iam_role", "app", ["create"], None, role),
    ]),
    "update-in-place.json": plan([
        rc("aws_instance.web", "aws_instance", "web", ["update"], web_before, web_after),
        rc("aws_s3_bucket.logs", "aws_s3_bucket", "logs", ["no-op"], bucket, bucket),
    ]),
    "replace-db.json": plan([
        rc("aws_db_instance.main", "aws_db_instance", "main", ["delete", "create"],
           db, {**db, "storage_encrypted": True,
                "kms_key_id": f"arn:aws:kms:eu-central-1:{ACCOUNT}:key/00000000-0000-0000-0000-000000000000"},
           reason="replace_because_cannot_update", replace_paths=[["storage_encrypted"]],
           before_sensitive=db_sensitive, after_sensitive=db_sensitive),
        rc("aws_instance.web", "aws_instance", "web", ["update"], web_before, web_after),
    ]),
    "delete-bucket.json": plan([
        rc("aws_s3_bucket.assets", "aws_s3_bucket", "assets", ["delete"],
           {**bucket, "bucket": "example-assets-bucket"}, None,
           reason="delete_because_no_resource_config"),
        rc("aws_s3_bucket_policy.assets", "aws_s3_bucket_policy", "assets", ["delete"],
           {"bucket": "example-assets-bucket", "policy": "{}"}, None,
           reason="delete_because_no_resource_config"),
        rc("aws_iam_role.app", "aws_iam_role", "app", ["no-op"], role, role),
    ]),
    "no-stateful-types.json": plan([
        rc("aws_instance.web", "aws_instance", "web", ["update"], web_before, web_after),
        rc("aws_iam_role.app", "aws_iam_role", "app", ["delete"], role, None,
           reason="delete_because_no_resource_config"),
    ]),
    "replace-create-first.json": plan([
        rc("aws_launch_template.web", "aws_launch_template", "web", ["create", "delete"],
           {"name": "example-web-v1", "image_id": "ami-0123456789abcdef0"},
           {"name": "example-web-v2", "image_id": "ami-0123456789abcdef0"},
           reason="replace_because_cannot_update", replace_paths=[["name"]]),
    ]),
    "sensitive.json": plan(
        [
            rc("aws_db_instance.main", "aws_db_instance", "main", ["update"],
               db, {**db, "password": "FAKE-SENSITIVE-PASSWORD-0002", "allocated_storage": 100},
               before_sensitive=db_sensitive, after_sensitive=db_sensitive),
        ],
        {
            "db_password": {
                "actions": ["update"],
                "before": "FAKE-SENSITIVE-PASSWORD-0001",
                "after": "FAKE-SENSITIVE-PASSWORD-0002",
                "after_unknown": False,
                "before_sensitive": True,
                "after_sensitive": True,
            },
            "db_endpoint": {
                "actions": ["no-op"],
                "before": "example-db.abc123.eu-central-1.rds.amazonaws.com:5432",
                "after": "example-db.abc123.eu-central-1.rds.amazonaws.com:5432",
                "after_unknown": False,
                "before_sensitive": False,
                "after_sensitive": False,
            },
        },
    ),
}

OUT.mkdir(parents=True, exist_ok=True)
for name, doc in fixtures.items():
    (OUT / name).write_text(json.dumps(doc, indent=2) + "\n")

# Not a plan: a document cut off part-way, as when a redirect is interrupted.
full = json.dumps(fixtures["update-in-place.json"], indent=2)
(OUT / "malformed.json").write_text(full[: len(full) // 2] + "\n")
print("wrote", sorted(p.name for p in OUT.iterdir()))
