# Demo 1: review a plan that replaces a database

A 60 to 90 second screen recording. The agent reviews a plan, flags that it replaces a
database, and stops before apply. Record it in Claude Code; the steps are the same in Cursor or
Codex.

## Before you record

1. Make an empty directory and copy `tests/fixtures/plans/replace-db.json` into it as
   `plan.json`. The plan is synthetic: the account ID and names are fake.
2. Install the skill there:
   `npx skills add https://github.com/StackGuardian/stackguardian-mcp/tree/main/standalone --skill terraform-plan-review -a claude-code -y`
3. Install Tirith in a virtual environment and activate it, so the policies run:
   `pip install "git+https://github.com/StackGuardian/tirith.git@1.2.1"`
4. Start Claude Code in the directory. Use a large terminal font and a clean prompt.
5. Do a full dry run once, then clear the session.

## Script

| Time | On screen | Voice-over |
| --- | --- | --- |
| 0:00 | The empty prompt and `plan.json` in the file list | "Here's a Terraform plan someone wants to apply. Let's have the agent look at it first." |
| 0:08 | Type: **Review the Terraform plan in plan.json before I apply it.** | |
| 0:12 | The agent loads `terraform-plan-review` and runs the three Tirith policies | "The skill runs Tirith policies against the plan: deletes, replacements and data-holding resources." |
| 0:30 | The report appears. Scroll to **Replacements and deletes** | "First thing in the report: the database. `aws_db_instance.main` is replaced, destroy first, because `storage_encrypted` changes. That means a new, empty database." |
| 0:50 | Scroll to **Tirith checks**: all three failed | "All three policies fail on it, and each says why." |
| 1:00 | Scroll to **Sensitive values** | "The database password is in the plan file in plain text. The report says it's there and doesn't show it." |
| 1:10 | Scroll to **Check before apply** | "And it stops here. It never runs apply; you decide what happens next." |
| 1:20 | End card: the install command | "Works with any repo, no account needed. The install command is in the README." |

## Check before publishing

- No real account IDs, names or credentials appear anywhere on screen.
- The password value from the fixture (`FAKE-SENSITIVE-PASSWORD-…`) never appears.
- The agent ran no `terraform` command.
