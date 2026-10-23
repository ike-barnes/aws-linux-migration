## Summary

<!-- What does this PR change? One or two sentences. -->

**Phase / Day:** <!-- e.g. Phase 2 / Day 06 -->
**Wave:** <!-- e.g. wave0, or n/a -->
**Change type:** <!-- infra | runbook | script | discovery-data -->
**Ticket:** <!-- e.g. MIG-123 -->

## Affected systems

| Host / Resource | Environment | Change |
|---|---|---|
| | | |

## Evidence

- [ ] `terraform fmt -check -recursive` passes
- [ ] `terraform validate` passes
- [ ] `terraform plan` output attached below (no unexpected destroys/replacements)
- [ ] `shellcheck` passes for any changed bash
- [ ] Preflight output attached for any host-level change (`scripts/aws-nitro-preflight.sh`)

<details><summary>terraform plan</summary>

```text
<paste plan>
```

</details>

## Risk assessment

- **Blast radius:** <!-- single host | wave | account | org -->
- **Downtime impact:** <!-- none | <N> minutes | maintenance window required -->
- **Data-loss risk:** <!-- none | describe -->

## Rollback

<!-- Exact commands. "Revert this PR" is not sufficient for stateful or host-level changes. -->

```bash
# rollback commands
```

- [ ] Rollback procedure tested (test launch / sandbox) or explicitly waived by migration lead

## Security checklist

- [ ] No credentials, keys, activation keys, or account-specific secrets committed
- [ ] IAM changes follow least privilege (no `*:*`, no new long-lived access keys)
- [ ] No security group opens `0.0.0.0/0` ingress
- [ ] Encryption at rest/in transit unchanged or improved

## Reviewers

- [ ] Peer engineer
- [ ] App owner (required for cutover/runbook changes)
- [ ] Security (required for IAM/SCP/SG changes)
