# One-way doors

Some actions are irreversible. Always require explicit user confirmation before executing any of these, regardless of context or autonomy level.

## Always confirm

- **Data deletion**: DROP TABLE, TRUNCATE, DELETE without WHERE, bulk deletes
- **Schema migrations**: ALTER TABLE, column drops, type changes, index drops
- **Credential rotation**: API key regeneration, secret rotation, token invalidation
- **DNS/domain changes**: CNAME, A record, nameserver changes
- **Service shutdown**: stopping production services, scaling to zero
- **Git history rewrite**: force push, rebase onto shared branches, squash of others' commits
- **Account/user deletion**: removing user accounts, revoking access
- **Environment variable changes in production**: anything touching prod env vars
- **Infrastructure teardown**: terraform destroy, deleting cloud resources
- **Payment/billing changes**: modifying subscription plans, pricing, billing configs

## How to confirm

Use AskUserQuestion with the specific action and its consequences. Include what will be destroyed and whether it can be recovered.

## Two-way doors (don't need confirmation)

- Creating files, branches, or resources (can be deleted)
- Adding environment variables (can be removed)
- Installing dependencies (can be uninstalled)
- Creating database records (can be deleted)
- Pushing to feature branches (can be reverted)
