# Power Platform Environment Group Rule Copier

This project provides two scripts for copying governance rules between Microsoft Power Platform environment groups in the same tenant:

| Script | Intended use |
|---|---|
| `Copy-PowerPlatformEnvironmentGroupRules.ps1` | Governed automation using a supplied API token or certificate-backed app registration |
| `Copy-PowerPlatformEnvironmentGroupRulesWithPac.ps1` | One-off local execution using an existing PAC CLI user profile |

## Why there are two scripts

Both scripts implement the same high-level workflow—read the source, back up the target, copy both governance surfaces, and verify the result—but they use different authentication and transport layers with different capabilities.

### API-authenticated script

`Copy-PowerPlatformEnvironmentGroupRules.ps1` calls the Power Platform REST APIs directly.

Advantages:

- Full control over every required endpoint
- Supports target-side deletion through `-Exact`
- Can remove and replace policy assignments safely
- Can delete unused policies
- Suitable for governed automation, CI/CD, and recovery workflows

Tradeoff:

- The caller must supply a Power Platform API token or a certificate-backed management application

### PAC one-off script

`Copy-PowerPlatformEnvironmentGroupRulesWithPac.ps1` delegates authentication and requests to supported `pac governance` commands.

Advantages:

- Uses an existing PAC user profile
- A Power Platform administrator can run it locally without creating an access token or app registration
- Better suited to occasional, attended administration

Tradeoffs:

- The PAC governance surface is currently preview
- PAC doesn't currently expose policy-assignment deletion or policy deletion
- It can't safely provide `-Exact` or every recovery path available through REST

Keeping the transports separate prevents the one-off convenience path from weakening or complicating the fully capable automation path. A single script with a transport switch is possible, but it would still need different behavior and safety rules for each transport.

### Which script should I use?

| Scenario | Script |
|---|---|
| Copy rules once as a signed-in Power Platform administrator | `Copy-PowerPlatformEnvironmentGroupRulesWithPac.ps1` |
| Scheduled or unattended automation | `Copy-PowerPlatformEnvironmentGroupRules.ps1` |
| CI/CD or workload identity | `Copy-PowerPlatformEnvironmentGroupRules.ps1` |
| Need `-Exact` deletion semantics | `Copy-PowerPlatformEnvironmentGroupRules.ps1` |
| Need assignment replacement or automated recovery | `Copy-PowerPlatformEnvironmentGroupRules.ps1` |
| Target is empty or has one exclusive policy and this is an attended run | Either; PAC is simpler |

The script reads and copies the opaque rule payloads exposed by both Power Platform governance API families:

1. Environment-group **Rule Sets**
2. Environment-group **Rule-Based Policies**

It does not maintain a fixed catalog of known Rules Gallery fields. New or unfamiliar rules can be copied when they are returned through either supported API.

## Features

- Read-only plan by default.
- Requires `-Apply` before making changes.
- Supports PowerShell `-WhatIf` and confirmation.
- Backs up the target configuration before writing.
- Stores backups outside Git worktrees by default.
- Restricts backup-file permissions to the current user.
- Copies both governance API surfaces.
- The API-authenticated script detects shared target policies and creates an independent replacement instead of modifying the shared policy.
- The PAC one-off script refuses unsupported replacement scenarios rather than attempting an unsafe partial operation.
- Reads the target back and verifies enforceable rule identities and values.
- Stops on API errors, ambiguous assignments, or verification mismatches.

## Requirements

### API-authenticated script

- PowerShell 7 or later
- Source and target environment groups in the same tenant
- A Power Platform API authentication method:
  - A caller-supplied access token, or
  - A governed certificate-backed app registration used through `MSAL.PS`
- An identity with permission to:
  - Read the source and target groups
  - Read their governance configuration
  - Create or update target governance configuration
  - Remove target configuration when `-Exact` is used

Power Platform Administrator or appropriately scoped Power Platform RBAC roles are typical choices.

### PAC one-off script

- PowerShell 7 or later
- Power Platform CLI with the generated `pac governance` commands
- PAC 2.12.2 or later is recommended
- An existing PAC user profile for the target tenant
- A signed-in user with sufficient Power Platform administrative permission

The PAC script uses supported PAC commands and does not read PAC's token cache.

## Parameters

### API-authenticated script

| Parameter | Required | Description |
|---|---:|---|
| `SourceGroupId` | Yes | Environment-group GUID to copy from. |
| `TargetGroupId` | Yes | Environment-group GUID to copy into. Must differ from the source. |
| `AccessToken` | Authentication option | Existing bearer token for `https://api.powerplatform.com`. |
| `ClientId` | Authentication option | Application/client ID of a Power Platform management application. |
| `TenantId` | With `ClientId` | Microsoft Entra tenant GUID for the app registration. |
| `ClientCertificate` | With `ClientId` | `X509Certificate2` containing the app registration's private key. |
| `Apply` | No | Enables writes. Without it, the script prints a plan and exits. |
| `Exact` | No | Deletes a target governance surface when that entire surface is absent from the source. |
| `BackupPath` | No | Explicit backup-file location. Must be outside a Git worktree. |

Supply one authentication option:

- `-AccessToken`, or
- `-ClientId`, `-TenantId`, and `-ClientCertificate`

`-AccessToken` takes precedence when both are supplied.

### PAC one-off script

| Parameter | Required | Description |
|---|---:|---|
| `SourceGroupId` | Yes | Environment-group GUID to copy from. |
| `TargetGroupId` | Yes | Environment-group GUID to copy into. |
| `PacPath` | No | PAC executable or command name. Defaults to `pac`. |
| `PacProfileIndex` | No | PAC authentication-profile index to use temporarily. `0` uses the active profile. |
| `Apply` | No | Enables writes. Without it, the script prints a plan and exits. |
| `BackupPath` | No | Explicit backup-file location outside a Git worktree. |

The PAC script intentionally doesn't implement `-Exact`.

## Authentication

### Existing access token

Use this option when authentication is handled by CI/CD, workload identity, a managed identity, or another governed token provider:

```powershell
$token = Get-ApprovedPowerPlatformApiToken

.\Copy-PowerPlatformEnvironmentGroupRules.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>" `
  -AccessToken $token
```

The token audience must be `https://api.powerplatform.com`.

Do not put bearer tokens in source files, shell history, logs, issue descriptions, or documentation.

### Certificate-backed app registration

Install `MSAL.PS` and use a Power Platform management application configured for certificate authentication and the required Power Platform access:

```powershell
Install-Module MSAL.PS -Scope CurrentUser
$certificate = Get-Item "Cert:\CurrentUser\My\<certificate-thumbprint>"

.\Copy-PowerPlatformEnvironmentGroupRules.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>" `
  -TenantId "<tenant-guid>" `
  -ClientId "<application-client-id>" `
  -ClientCertificate $certificate
```

The service principal must be registered as a Power Platform management application and assigned sufficient Power Platform RBAC permissions. The certificate object must include its private key.

## Finding environment-group IDs

With a current Power Platform CLI installation and an authenticated administrator profile:

```powershell
pac admin list-groups
```

Newer PAC versions may expose equivalent commands under:

```powershell
pac environment-management
pac governance
```

Confirm the source and target names and GUIDs before applying changes.

## Usage

### One-off local use with PAC

Confirm the desired profile:

```powershell
pac auth list
pac admin list-groups
```

Run a read-only plan using the active profile:

```powershell
.\Copy-PowerPlatformEnvironmentGroupRulesWithPac.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>"
```

Or select a profile for only this run:

```powershell
.\Copy-PowerPlatformEnvironmentGroupRulesWithPac.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>" `
  -PacProfileIndex 3
```

Apply:

```powershell
.\Copy-PowerPlatformEnvironmentGroupRulesWithPac.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>" `
  -PacProfileIndex 3 `
  -Apply
```

When `PacProfileIndex` changes the active PAC profile, the script restores the formerly active profile in `finally`.

The PAC wrapper supports:

- Creating a missing target Rule Set
- Updating an existing target Rule Set
- Creating and assigning a missing target policy
- Updating an existing target policy with one assignment
- Backup and semantic read-back verification

PAC currently doesn't expose policy-assignment deletion or policy deletion. Consequently, the one-off wrapper:

- Leaves target configuration unchanged when the corresponding source surface is absent
- Refuses policy replacement when the target policy has multiple assignments
- Warns with the orphan policy ID if policy creation succeeds but assignment fails
- Doesn't provide `-Exact`

Use the API-authenticated script when deletion, assignment replacement, or fully automated recovery behavior is required.

### API-authenticated usage

### Read-only plan

Omit `-Apply`:

```powershell
$certificate = Get-Item "Cert:\CurrentUser\My\<certificate-thumbprint>"

.\Copy-PowerPlatformEnvironmentGroupRules.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>" `
  -TenantId "<tenant-guid>" `
  -ClientId "<application-client-id>" `
  -ClientCertificate $certificate
```

Example plan output:

```text
SourceGroupId           : ...
TargetGroupId           : ...
LegacyRules             : {Sharing/App (...), Lifecycle/NotSpecified (...)}
PolicyRules             : {AdvancedConnectorPoliciesOnly, ConnectorManagement}
TargetPolicyAssignments : 2
TargetPolicyShared      : True
Apply                   : False
Exact                   : False

Plan only. Re-run with -Apply to write the target group.
```

The plan inventories source rules and reports whether the target policy is shared. It is not a full source-versus-target diff.

### Apply the copy

```powershell
$certificate = Get-Item "Cert:\CurrentUser\My\<certificate-thumbprint>"

.\Copy-PowerPlatformEnvironmentGroupRules.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>" `
  -TenantId "<tenant-guid>" `
  -ClientId "<application-client-id>" `
  -ClientCertificate $certificate `
  -Apply
```

The script requests high-impact confirmation before creating the backup or writing any target configuration.

### Preview with `-WhatIf`

```powershell
$certificate = Get-Item "Cert:\CurrentUser\My\<certificate-thumbprint>"

.\Copy-PowerPlatformEnvironmentGroupRules.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>" `
  -TenantId "<tenant-guid>" `
  -ClientId "<application-client-id>" `
  -ClientCertificate $certificate `
  -Apply `
  -WhatIf
```

`-WhatIf` performs no writes and creates no backup.

### Use an explicit backup path

```powershell
$certificate = Get-Item "Cert:\CurrentUser\My\<certificate-thumbprint>"

.\Copy-PowerPlatformEnvironmentGroupRules.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>" `
  -TenantId "<tenant-guid>" `
  -ClientId "<application-client-id>" `
  -ClientCertificate $certificate `
  -BackupPath "C:\ProtectedAdminData\environment-group-backup.json" `
  -Apply
```

The path must be outside a Git worktree.

### Exact mode

```powershell
$certificate = Get-Item "Cert:\CurrentUser\My\<certificate-thumbprint>"

.\Copy-PowerPlatformEnvironmentGroupRules.ps1 `
  -SourceGroupId "<source-group-guid>" `
  -TargetGroupId "<target-group-guid>" `
  -TenantId "<tenant-guid>" `
  -ClientId "<application-client-id>" `
  -ClientCertificate $certificate `
  -Apply `
  -Exact
```

Use `-Exact` cautiously:

- If the source has no legacy Rule Set, the target legacy Rule Set is deleted.
- If the source has no Rule-Based Policy, the target group's policy assignment is removed.
- An unassigned target policy is deleted only when it has no other assignments.

When the source has a governance surface, the corresponding target surface is replaced regardless of `-Exact`.

## What the script copies

### Environment-group Rule Sets

Endpoints:

```text
GET  /governance/environmentGroups/{groupId}/ruleSets
POST /governance/environmentGroups/{groupId}/ruleSets
PUT  /governance/ruleSets/{ruleSetId}
DELETE /governance/ruleSets/{ruleSetId}
```

The script copies:

- `parameters[].type`
- `parameters[].resourceType`
- `parameters[].value[].id`
- `parameters[].value[].value`

The target environment filter is rewritten to reference the target group. Source IDs and timestamps aren't copied.

### Rule-Based Policies

Endpoints:

```text
GET    /governance/ruleBasedPolicies/environmentGroups/{groupId}/assignments
GET    /governance/ruleBasedPolicies/{policyId}
GET    /governance/ruleBasedPolicies/{policyId}/assignments
POST   /governance/ruleBasedPolicies
PUT    /governance/ruleBasedPolicies/{policyId}
POST   /governance/ruleBasedPolicies/{policyId}/environmentGroups/{groupId}/assignments
DELETE /governance/ruleBasedPolicies/{policyId}/environmentGroups/{groupId}/assignments
DELETE /governance/ruleBasedPolicies/{policyId}
```

The script copies:

- `ruleSets[].id`
- `ruleSets[].version`
- `ruleSets[].inputs`

## Policy-assignment safety

The current service rejected an attempt to assign one policy to multiple entities during validation. The API nevertheless exposes policy-wide assignment enumeration, and future behavior or migrated tenant state could return more than one assignment. Updating such a policy in place would affect every assignment.

Before modifying an existing target policy, the script lists all of its assignments.

- If the target policy is assigned only to the target group, it is updated in place.
- If it has any other assignment, the script:
  1. Creates a new independent policy containing the source rules.
  2. Removes only the target group's old assignment.
  3. Assigns the new policy to the target group.
  4. Leaves the original shared policy unchanged for its other assignments.

If assigning the replacement fails, the script attempts to restore the former target assignment and delete the unused replacement policy before returning the error.

## Backups

### Default location

When `-BackupPath` is omitted, backups are written outside the working directory:

Windows:

```text
%LOCALAPPDATA%\PowerPlatformEnvironmentGroupRuleCopier\Backups\
```

Other platforms:

```text
~/.powerplatform-environment-group-rule-copier/backups/
```

Generated filenames contain a timestamp and random suffix, but no tenant or group GUID.

### Backup contents

The JSON backup includes:

- Capture time in UTC
- Target group ID
- Target legacy Rule Set response
- Target Rule-Based Policy response
- Existing assignments for the target policy

Backups contain internal governance configuration. The script restricts the file to the current user and rejects paths inside Git worktrees.

### Rollback

Automated restore is not currently implemented.

Practical rollback options:

- Copy from a known-good environment group back into the target.
- Use the backup payload to recreate/update the target Rule Set and Rule-Based Policy through the Power Platform APIs.

Preserve the backup until the result has been reviewed in Power Platform admin center.

## Verification

The Power Platform service rewrites IDs, timestamps, ordering, and other metadata. Raw JSON equality is therefore unreliable.

The script compares semantic content after the copy.

Legacy Rule Set comparison:

- Parameter `type`
- Parameter `resourceType`
- Rule-value `id`
- Rule-value `value`

Rule-Based Policy comparison:

- Rule-set `id`
- Rule-set `version`
- Rule-set `inputs`

Success requires:

```text
LegacyRulesMatch : True
PolicyRulesMatch : True
```

If either comparison fails, the script throws and reports the backup path.

## Validation history

The core copy behavior was validated end to end in an isolated nonproduction tenant:

1. Two disposable environment groups were created.
2. The source group was seeded with legacy rules from multiple categories.
3. The source group was assigned a policy-backed rule.
4. The script copied both API surfaces.
5. The target was read back independently.
6. Semantic verification passed for both surfaces.
7. All test policies, assignments, rule sets, groups, and backups were deleted.

Additional mocked regression coverage verifies:

- Creating missing target governance surfaces
- Updating an existing target
- Isolating a target when a policy has multiple assignments
- `-WhatIf` creating no backup and issuing no writes
- Secure default backup location and current-user-only permissions

The certificate-backed app-registration path was also validated end to end with a disposable application, certificate, Power Platform management-application registration, and scoped administrative setup in an isolated nonproduction tenant. Plan, apply, and semantic read-back all succeeded, and every temporary identity and governance resource was removed afterward.

The PAC one-off wrapper was validated separately with PAC 2.12.2 and an existing user profile:

- Complete JSON reads for both governance surfaces
- Rule Set creation and update
- Rule-Based Policy creation and update
- Environment-group policy assignment
- Copy into an empty target
- Copy into an already-configured target
- Semantic read-back verification
- Backup protection
- Temporary PAC profile selection and restoration

All disposable validation groups, rules, policies, assignments, backups, and isolated PAC tooling were removed afterward.

This proves the two API paths exercised by the tests. It doesn't guarantee that every current or future Rules Gallery entry is exposed through these APIs.

## Known limitations

- The script can copy only configuration exposed through the Rule Sets and Rule-Based Policies APIs.
- It performs a one-time copy, not continuous synchronization.
- Plan mode inventories source rules but doesn't yet display a full semantic target diff.
- Restore from backup is manual.
- API responses are expected to contain at most one legacy Rule Set and one policy assignment per environment group.
- Existing target rule contents are replaced, not merged.
- The `2024-10-01` API contract can evolve.
- The PAC wrapper depends on preview `pac governance` commands.
- The PAC wrapper can't delete policy assignments or policies with the current PAC command surface.
- The PAC wrapper requires careful array-preserving JSON serialization because PAC accepts JSON values as command arguments.

## Troubleshooting

### `403 Forbidden`

Authentication succeeded, but the identity lacks effective permission.

Check:

- Token tenant and audience
- Power Platform administrator or scoped RBAC role
- Read access to source and target
- Write access to the target

### `MSAL.PS is required`

Install it:

```powershell
Install-Module MSAL.PS -Scope CurrentUser
```

Or provide `-AccessToken`.

### `Provide -ClientCertificate when using -ClientId`

Load a certificate containing its private key:

```powershell
$certificate = Get-Item "Cert:\CurrentUser\My\<certificate-thumbprint>"
```

Confirm:

```powershell
$certificate.HasPrivateKey
```

The result must be `True`.

### `returned more than one policy assignment`

The script intentionally stops because its one-policy-per-group assumption is no longer safe.

Do not change the script to select the first result. Investigate the assignments and update the design explicitly.

### Backup path rejected

The selected path is inside a Git worktree. Choose a protected administrative directory outside source control.

### PAC reports that governance commands don't exist

Upgrade PAC. Version 2.12.2 or later is recommended:

```powershell
pac governance help
```

The output must include commands such as `get-rule-set`, `create-rule-set`, and `create-rule-based-policy`.

### PAC command returns a JSON validation error

Use the provided PAC wrapper rather than manually passing PowerShell-generated JSON. The wrapper preserves single-item arrays and uses PAC's Newtonsoft serializer to avoid Windows native-argument quoting issues.

### Read-back verification failed

1. Preserve the backup.
2. Query both source and target API surfaces.
3. Compare normalized rule IDs and values.
4. Check whether the service rejected or normalized a tenant-, region-, or preview-specific rule.
5. Don't blindly retry until the previous operation's state is understood.

## Development guidance

Preserve these properties:

- Opaque rule copying instead of fixed rule catalogs
- Strict mode
- Fail-fast API error handling
- Assignment-cardinality checks
- Shared-policy isolation
- Backup-before-write
- Semantic read-back verification
- PAC profile restoration in the one-off wrapper
- Array-preserving PAC JSON serialization

Recommended enhancement order:

1. Add automated restore from backup.
2. Add a full semantic source-versus-target diff.
3. Add structured `-PassThru` or JSON output.
4. Add maintained Pester tests.
5. Add ETag or last-modified concurrency protection.
6. Evaluate newer `pac governance` commands as a supported transport while retaining opaque payload fidelity and verification.

Minimum integration regression:

1. Use an isolated nonproduction tenant.
2. Create two disposable groups.
3. Seed multiple legacy rule types.
4. Seed at least one policy-backed rule.
5. Test plan, `-WhatIf`, apply, and exact behavior.
6. Retain a mocked multiple-assignment regression even if the live service currently prevents creating that state.
7. Verify both API surfaces independently.
8. Delete every test artifact in `finally`.

## Public-release checklist

- [ ] Add an appropriate open-source license.
- [ ] Add Pester tests to the repository.
- [ ] Add backup files and administrative output to `.gitignore`.
- [ ] Document the tested PowerShell, PAC, and API versions.
- [ ] Run secret scanning before release.
- [ ] Run static analysis such as PSScriptAnalyzer.
- [ ] Revalidate in an isolated nonproduction tenant after material changes.
- [ ] Review dependency and API changes before each release.

## References

- Environment groups:  
  <https://learn.microsoft.com/power-platform/admin/environment-groups>
- Rules for environment groups:  
  <https://learn.microsoft.com/power-platform/admin/environment-groups-rules>
- Environment Group Rules Gallery:  
  <https://learn.microsoft.com/power-platform/admin/environment-group-rules-gallery>
- Rule Sets REST API:  
  <https://learn.microsoft.com/rest/api/power-platform/governance/rule-sets>
- Rule-Based Policies REST API:  
  <https://learn.microsoft.com/rest/api/power-platform/governance/rule-based-policies>
- Power Platform API authentication:  
  <https://learn.microsoft.com/power-platform/admin/programmability-authentication-v2>
- Power Platform API permission reference:  
  <https://learn.microsoft.com/power-platform/admin/programmability-permission-reference>
- Power Platform RBAC:  
  <https://learn.microsoft.com/power-platform/admin/security/role-based-access-control>
- PAC governance commands:  
  <https://learn.microsoft.com/power-platform/developer/cli/reference/governance>
- Microsoft Power Platform Terraform provider reference:  
  <https://github.com/microsoft/terraform-provider-power-platform/tree/main/internal/services/environment_group_rule_set>
