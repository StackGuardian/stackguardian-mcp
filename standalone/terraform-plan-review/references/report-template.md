# Plan review report template

Fill every section. Write "None" when a section has nothing in it, so the reader knows it was
checked. Use full resource addresses (`module.db.aws_db_instance.main`), never only the name.

```markdown
## Plan review: <directory or workspace>

**Summary:** <n> to create, <n> to update in place, <n> to replace, <n> to delete, <n> unchanged.

### Replacements and deletes

| Resource               | Change                 | Why                                    |
| ---------------------- | ---------------------- | -------------------------------------- |
| `aws_db_instance.main` | Replace, destroy first | `storage_encrypted` forces replacement |
| `aws_s3_bucket.assets` | Delete                 | No longer in the configuration         |

### Tirith checks

| Policy              | Result | Details                                                 |
| ------------------- | ------ | ------------------------------------------------------- |
| no-stateful-deletes | Failed | `aws_db_instance.main` is replaced                      |
| no-replacements     | Failed | `aws_db_instance.main` is replaced                      |
| no-deletes          | Failed | `aws_s3_bucket.assets` deleted; 1 more in a replacement |

### Other changes

- `aws_instance.web`: update in place, `instance_type` t3.small → t3.medium

### Sensitive values

- `aws_db_instance.main`: `password` is sensitive and changes. Value not shown.
- Output `db_password` is sensitive. Value not shown.

### Check before apply

- <a question the plan raises, e.g. "Is there a recent snapshot of example-db?">

### What this plan cannot tell you

- Whether the application tolerates the downtime of a destroy-first replacement.
- Whether data inside a resource that is only updated is affected.
- Changes made outside Terraform after this plan was created.
```
