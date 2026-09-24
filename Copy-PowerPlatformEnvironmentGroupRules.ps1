[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory)]
    [guid]$SourceGroupId,

    [Parameter(Mandatory)]
    [guid]$TargetGroupId,

    [string]$AccessToken,

    [string]$ClientId,

    [guid]$TenantId,

    [Security.Cryptography.X509Certificates.X509Certificate2]$ClientCertificate,

    [switch]$Apply,

    [switch]$Exact,

    [string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$apiBaseUrl = "https://api.powerplatform.com"
$apiVersion = "2024-10-01"

function Get-PowerPlatformAccessToken {
    if ($AccessToken) {
        return $AccessToken
    }

    if (-not $ClientId) {
        throw "Provide -AccessToken or -ClientId."
    }
    if ($TenantId -eq [guid]::Empty) {
        throw "Provide -TenantId when using -ClientId."
    }
    if (-not $ClientCertificate) {
        throw "Provide -ClientCertificate when using -ClientId."
    }

    if (-not (Get-Command Get-MsalToken -ErrorAction SilentlyContinue)) {
        throw "MSAL.PS is required for certificate authentication. Install it, or provide -AccessToken."
    }

    $authParameters = @{
        TenantId          = $TenantId
        ClientId          = $ClientId
        Scope             = "$apiBaseUrl/.default"
        ClientCertificate = $ClientCertificate
    }

    $auth = Get-MsalToken @authParameters

    if (-not $auth.AccessToken) {
        throw "Certificate authentication did not return an access token."
    }

    return $auth.AccessToken
}

function Invoke-PowerPlatformRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("GET", "POST", "PUT", "DELETE")]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [object]$Body
    )

    $parameters = @{
        Method  = $Method
        Uri     = "$apiBaseUrl$Path"
        Headers = @{
            Authorization = "Bearer $token"
        }
    }

    if ($PSBoundParameters.ContainsKey("Body")) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body | ConvertTo-Json -Depth 100
    }

    try {
        return Invoke-RestMethod @parameters
    }
    catch {
        $responseBody = $null
        if ($null -ne $_.ErrorDetails) {
            $responseBody = $_.ErrorDetails.Message
        }
        if (-not $responseBody) {
            $responseBody = $_.Exception.Message
        }

        throw "$Method $($parameters.Uri) failed: $responseBody"
    }
}

function Test-ObjectMember {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    if ($InputObject -is [Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }

    return $InputObject.PSObject.Properties.Name -contains $Name
}

function Get-EnvironmentGroupRuleSet {
    param(
        [Parameter(Mandatory)]
        [guid]$GroupId
    )

    $response = Invoke-PowerPlatformRequest `
        -Method GET `
        -Path "/governance/environmentGroups/$GroupId/ruleSets?api-version=$apiVersion"

    if (
        $null -eq $response -or
        -not (Test-ObjectMember -InputObject $response -Name "value") -or
        @($response.value).Count -eq 0
    ) {
        return $null
    }

    if (@($response.value).Count -ne 1) {
        throw "Environment group $GroupId returned $(@($response.value).Count) rule sets; expected at most one."
    }

    return $response.value[0]
}

function Get-EnvironmentGroupPolicy {
    param(
        [Parameter(Mandatory)]
        [guid]$GroupId
    )

    $assignments = Invoke-PowerPlatformRequest `
        -Method GET `
        -Path "/governance/ruleBasedPolicies/environmentGroups/$GroupId/assignments?includeRuleSetCounts=true&api-version=$apiVersion"

    if (
        $null -eq $assignments -or
        -not (Test-ObjectMember -InputObject $assignments -Name "value") -or
        @($assignments.value).Count -eq 0
    ) {
        return $null
    }

    if (@($assignments.value).Count -ne 1) {
        throw "Environment group $GroupId returned $(@($assignments.value).Count) policy assignments; expected at most one."
    }

    $policyId = $assignments.value[0].policyId
    if (-not $policyId) {
        throw "The policy assignment for environment group $GroupId did not contain policyId."
    }

    return Invoke-PowerPlatformRequest `
        -Method GET `
        -Path "/governance/ruleBasedPolicies/$policyId`?api-version=$apiVersion"
}

function Get-PolicyAssignments {
    param(
        [Parameter(Mandatory)]
        [string]$PolicyId
    )

    $response = Invoke-PowerPlatformRequest `
        -Method GET `
        -Path "/governance/ruleBasedPolicies/$PolicyId/assignments?includeRuleSetCounts=true&api-version=$apiVersion"

    if (
        $null -eq $response -or
        -not (Test-ObjectMember -InputObject $response -Name "value")
    ) {
        return @()
    }

    return @($response.value)
}

function ConvertTo-CanonicalNode {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string] -or $InputObject.GetType().IsValueType) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in ($InputObject.Keys | Sort-Object)) {
            $ordered[$key] = ConvertTo-CanonicalNode $InputObject[$key]
        }
        return [pscustomobject]$ordered
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $nodes = @(
            foreach ($item in $InputObject) {
                ConvertTo-CanonicalNode $item
            }
        )

        return @(
            $nodes |
                Sort-Object {
                    $_ | ConvertTo-Json -Depth 100 -Compress
                }
        )
    }

    $properties = $InputObject.PSObject.Properties |
        Where-Object MemberType -in NoteProperty, Property |
        Sort-Object Name

    $result = [ordered]@{}
    foreach ($property in $properties) {
        $result[$property.Name] = ConvertTo-CanonicalNode $property.Value
    }

    return [pscustomobject]$result
}

function Get-CanonicalJson {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    return ConvertTo-CanonicalNode $InputObject |
        ConvertTo-Json -Depth 100 -Compress
}

function Get-LegacyRuleSummary {
    param(
        [AllowNull()]
        [object]$RuleSet
    )

    if ($null -eq $RuleSet -or $null -eq $RuleSet.parameters) {
        return @()
    }

    return @(
        $RuleSet.parameters |
            ForEach-Object {
                "{0}/{1} ({2} values)" -f $_.type, $_.resourceType, @($_.value).Count
            } |
            Sort-Object
    )
}

function Get-PolicyRuleSummary {
    param(
        [AllowNull()]
        [object]$Policy
    )

    if ($null -eq $Policy -or $null -eq $Policy.ruleSets) {
        return @()
    }

    return @(
        $Policy.ruleSets |
            ForEach-Object { $_.id } |
            Sort-Object
    )
}

function New-TargetRuleSetBody {
    param(
        [Parameter(Mandatory)]
        [object]$SourceRuleSet,

        [Parameter(Mandatory)]
        [guid]$TargetId,

        [AllowNull()]
        [object]$ExistingTargetRuleSet
    )

    $body = [ordered]@{
        lastModified = (Get-Date).ToUniversalTime().ToString("o")
        environmentFilter = @{
            type   = "Include"
            values = @(
                @{
                    id   = $TargetId.ToString()
                    type = "EnvironmentGroup"
                }
            )
        }
        parameters = $SourceRuleSet.parameters
    }

    if ($null -ne $ExistingTargetRuleSet -and $ExistingTargetRuleSet.id) {
        $body.id = $ExistingTargetRuleSet.id
    }

    return $body
}

function Copy-LegacyRuleSet {
    param(
        [AllowNull()]
        [object]$SourceRuleSet,

        [AllowNull()]
        [object]$TargetRuleSet
    )

    if ($null -eq $SourceRuleSet) {
        if ($Exact -and $null -ne $TargetRuleSet) {
            Invoke-PowerPlatformRequest `
                -Method DELETE `
                -Path "/governance/ruleSets/$($TargetRuleSet.id)?api-version=$apiVersion" |
                Out-Null
        }
        return
    }

    $body = New-TargetRuleSetBody `
        -SourceRuleSet $SourceRuleSet `
        -TargetId $TargetGroupId `
        -ExistingTargetRuleSet $TargetRuleSet

    if ($null -eq $TargetRuleSet) {
        Invoke-PowerPlatformRequest `
            -Method POST `
            -Path "/governance/environmentGroups/$TargetGroupId/ruleSets?api-version=$apiVersion" `
            -Body $body |
            Out-Null
    }
    else {
        Invoke-PowerPlatformRequest `
            -Method PUT `
            -Path "/governance/ruleSets/$($TargetRuleSet.id)?api-version=$apiVersion" `
            -Body $body |
            Out-Null
    }
}

function New-CopiedPolicy {
    param(
        [Parameter(Mandatory)]
        [object]$SourcePolicy
    )

    $policy = Invoke-PowerPlatformRequest `
        -Method POST `
        -Path "/governance/ruleBasedPolicies?api-version=$apiVersion" `
        -Body @{
            name     = "$($SourcePolicy.name) (copy)"
            ruleSets = $SourcePolicy.ruleSets
        }

    if (-not $policy.id) {
        throw "Creating the target rule-based policy did not return an id."
    }

    return $policy
}

function Add-EnvironmentGroupPolicyAssignment {
    param(
        [Parameter(Mandatory)]
        [string]$PolicyId
    )

    Invoke-PowerPlatformRequest `
        -Method POST `
        -Path "/governance/ruleBasedPolicies/$PolicyId/environmentGroups/$TargetGroupId/assignments?api-version=$apiVersion" `
        -Body @{ assignmentOverrides = @() } |
        Out-Null
}

function Remove-EnvironmentGroupPolicyAssignment {
    param(
        [Parameter(Mandatory)]
        [string]$PolicyId
    )

    Invoke-PowerPlatformRequest `
        -Method DELETE `
        -Path "/governance/ruleBasedPolicies/$PolicyId/environmentGroups/$TargetGroupId/assignments?api-version=$apiVersion" |
        Out-Null
}

function Copy-RuleBasedPolicy {
    param(
        [AllowNull()]
        [object]$SourcePolicy,

        [AllowNull()]
        [object]$TargetPolicy
    )

    $targetAssignments = @(
        if ($null -ne $TargetPolicy) {
            Get-PolicyAssignments -PolicyId $TargetPolicy.id
        }
    )

    $targetGroupAssignment = @(
        $targetAssignments |
            Where-Object {
                $_.resourceType -eq "EnvironmentGroup" -and
                $_.resourceId -eq $TargetGroupId.ToString()
            }
    )

    if ($null -ne $TargetPolicy -and $targetGroupAssignment.Count -ne 1) {
        throw "Policy $($TargetPolicy.id) has $($targetGroupAssignment.Count) assignments for target group $TargetGroupId; expected exactly one."
    }

    $otherAssignments = @(
        $targetAssignments |
            Where-Object {
                -not (
                    $_.resourceType -eq "EnvironmentGroup" -and
                    $_.resourceId -eq $TargetGroupId.ToString()
                )
            }
    )

    if ($null -eq $SourcePolicy) {
        if ($Exact -and $null -ne $TargetPolicy) {
            Remove-EnvironmentGroupPolicyAssignment -PolicyId $TargetPolicy.id

            if ($otherAssignments.Count -eq 0) {
                Invoke-PowerPlatformRequest `
                    -Method DELETE `
                    -Path "/governance/ruleBasedPolicies/$($TargetPolicy.id)?api-version=$apiVersion" |
                    Out-Null
            }
        }
        return
    }

    if ($null -eq $TargetPolicy) {
        $newPolicy = New-CopiedPolicy -SourcePolicy $SourcePolicy
        try {
            Add-EnvironmentGroupPolicyAssignment -PolicyId $newPolicy.id
        }
        catch {
            try {
                Invoke-PowerPlatformRequest `
                    -Method DELETE `
                    -Path "/governance/ruleBasedPolicies/$($newPolicy.id)?api-version=$apiVersion" |
                    Out-Null
            }
            catch {
                Write-Warning "Failed to delete unassigned policy $($newPolicy.id) after assignment failure."
            }
            throw
        }
        return
    }

    if ($otherAssignments.Count -eq 0 -and $targetAssignments.Count -eq 1) {
        Invoke-PowerPlatformRequest `
            -Method PUT `
            -Path "/governance/ruleBasedPolicies/$($TargetPolicy.id)?api-version=$apiVersion" `
            -Body @{
                name     = $TargetPolicy.name
                ruleSets = $SourcePolicy.ruleSets
            } |
            Out-Null
        return
    }

    $replacementPolicy = New-CopiedPolicy -SourcePolicy $SourcePolicy
    Remove-EnvironmentGroupPolicyAssignment -PolicyId $TargetPolicy.id

    try {
        Add-EnvironmentGroupPolicyAssignment -PolicyId $replacementPolicy.id
    }
    catch {
        try {
            Add-EnvironmentGroupPolicyAssignment -PolicyId $TargetPolicy.id
        }
        catch {
            Write-Warning "Failed to restore the target group's original policy assignment after replacement failed."
        }

        try {
            Invoke-PowerPlatformRequest `
                -Method DELETE `
                -Path "/governance/ruleBasedPolicies/$($replacementPolicy.id)?api-version=$apiVersion" |
                Out-Null
        }
        catch {
            Write-Warning "Failed to delete replacement policy $($replacementPolicy.id) after assignment failure."
        }

        throw
    }
}

function Test-CopyResult {
    param(
        [AllowNull()]
        [object]$ExpectedRuleSet,

        [AllowNull()]
        [object]$ExpectedPolicy,

        [AllowNull()]
        [object]$ActualRuleSet,

        [AllowNull()]
        [object]$ActualPolicy
    )

    $normalizeLegacyRules = {
        param([AllowNull()][object]$RuleSet)

        if ($null -eq $RuleSet) {
            return $null
        }

        return @(
            foreach ($parameter in @($RuleSet.parameters)) {
                [pscustomobject]@{
                    type         = $parameter.type
                    resourceType = $parameter.resourceType
                    value        = @(
                        foreach ($item in @($parameter.value)) {
                            [pscustomobject]@{
                                id    = $item.id
                                value = $item.value
                            }
                        }
                    )
                }
            }
        )
    }

    $normalizePolicyRules = {
        param([AllowNull()][object]$Policy)

        if ($null -eq $Policy) {
            return $null
        }

        return @(
            foreach ($ruleSet in @($Policy.ruleSets)) {
                [pscustomobject]@{
                    id      = $ruleSet.id
                    version = $ruleSet.version
                    inputs  = $ruleSet.inputs
                }
            }
        )
    }

    $expectedLegacyRules = & $normalizeLegacyRules $ExpectedRuleSet
    $actualLegacyRules = & $normalizeLegacyRules $ActualRuleSet
    $expectedPolicyRules = & $normalizePolicyRules $ExpectedPolicy
    $actualPolicyRules = & $normalizePolicyRules $ActualPolicy

    $expectedLegacy = Get-CanonicalJson $expectedLegacyRules
    $actualLegacy = Get-CanonicalJson $actualLegacyRules
    $expectedPolicy = Get-CanonicalJson $expectedPolicyRules
    $actualPolicy = Get-CanonicalJson $actualPolicyRules

    [pscustomobject]@{
        LegacyRulesMatch = $expectedLegacy -eq $actualLegacy
        PolicyRulesMatch = $expectedPolicy -eq $actualPolicy
    }
}

function Test-PathInsideGitWorktree {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return $false
    }

    $directory = if (Test-Path -LiteralPath $Path -PathType Container) {
        $Path
    }
    else {
        Split-Path -Parent $Path
    }

    if (-not $directory -or -not (Test-Path -LiteralPath $directory)) {
        return $false
    }

    try {
        $result = & git -C $directory rev-parse --is-inside-work-tree 2>$null
        return $LASTEXITCODE -eq 0 -and $result -eq "true"
    }
    catch {
        return $false
    }
}

function Resolve-BackupPath {
    if ($BackupPath) {
        $resolvedPath = if ([IO.Path]::IsPathRooted($BackupPath)) {
            [IO.Path]::GetFullPath($BackupPath)
        }
        else {
            [IO.Path]::GetFullPath(
                (Join-Path (Get-Location) $BackupPath)
            )
        }
    }
    else {
        $backupRoot = if ($IsWindows -and $env:LOCALAPPDATA) {
            Join-Path $env:LOCALAPPDATA "PowerPlatformEnvironmentGroupRuleCopier\Backups"
        }
        else {
            Join-Path $HOME ".powerplatform-environment-group-rule-copier/backups"
        }

        $fileName = "environment-group-rules-{0}-{1}.backup.json" -f `
            (Get-Date -Format "yyyyMMdd-HHmmss"), `
            ([guid]::NewGuid().ToString("N").Substring(0, 8))
        $resolvedPath = Join-Path $backupRoot $fileName
    }

    $parent = Split-Path -Parent $resolvedPath
    if (-not $parent) {
        throw "BackupPath must include a parent directory."
    }

    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    if (Test-PathInsideGitWorktree -Path $resolvedPath) {
        throw "BackupPath must be outside a Git worktree to reduce accidental-commit risk."
    }

    return $resolvedPath
}

function Protect-BackupFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($IsWindows) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetOwner($identity)
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule(
            (New-Object Security.AccessControl.FileSystemAccessRule(
                $identity,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow
            ))
        )
        Set-Acl -LiteralPath $Path -AclObject $acl
        return
    }

    [IO.File]::SetUnixFileMode(
        $Path,
        [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
    )
}

if ($SourceGroupId -eq $TargetGroupId) {
    throw "SourceGroupId and TargetGroupId must be different."
}

$token = Get-PowerPlatformAccessToken

$sourceRuleSet = Get-EnvironmentGroupRuleSet -GroupId $SourceGroupId
$targetRuleSet = Get-EnvironmentGroupRuleSet -GroupId $TargetGroupId
$sourcePolicy = Get-EnvironmentGroupPolicy -GroupId $SourceGroupId
$targetPolicy = Get-EnvironmentGroupPolicy -GroupId $TargetGroupId
$targetPolicyAssignments = @(
    if ($null -ne $targetPolicy) {
        Get-PolicyAssignments -PolicyId $targetPolicy.id
    }
)

$plan = [pscustomobject]@{
    SourceGroupId           = $SourceGroupId
    TargetGroupId           = $TargetGroupId
    LegacyRules             = Get-LegacyRuleSummary $sourceRuleSet
    PolicyRules             = Get-PolicyRuleSummary $sourcePolicy
    TargetPolicyAssignments = $targetPolicyAssignments.Count
    TargetPolicyShared      = $targetPolicyAssignments.Count -gt 1
    Apply                   = [bool]$Apply
    Exact                   = [bool]$Exact
}

$plan | Format-List

if (-not $Apply) {
    Write-Host "Plan only. Re-run with -Apply to write the target group."
    return
}

if (-not $PSCmdlet.ShouldProcess(
        "environment group $TargetGroupId",
        "replace exposed rule-set and rule-based-policy configuration from $SourceGroupId"
    )) {
    Write-Host "No changes made."
    $token = $null
    return
}

$BackupPath = Resolve-BackupPath
$backup = @{
    capturedAtUtc    = (Get-Date).ToUniversalTime().ToString("o")
    groupId          = $TargetGroupId
    ruleSet          = $targetRuleSet
    policy           = $targetPolicy
    policyAssignments = $targetPolicyAssignments
}
try {
    $backup | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $BackupPath -Encoding utf8NoBOM
    Protect-BackupFile -Path $BackupPath
}
catch {
    Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
    throw
}
Write-Host "Target backup written to $BackupPath"

Copy-LegacyRuleSet -SourceRuleSet $sourceRuleSet -TargetRuleSet $targetRuleSet
Copy-RuleBasedPolicy -SourcePolicy $sourcePolicy -TargetPolicy $targetPolicy

$verifiedRuleSet = Get-EnvironmentGroupRuleSet -GroupId $TargetGroupId
$verifiedPolicy = Get-EnvironmentGroupPolicy -GroupId $TargetGroupId
$verification = Test-CopyResult `
    -ExpectedRuleSet $sourceRuleSet `
    -ExpectedPolicy $sourcePolicy `
    -ActualRuleSet $verifiedRuleSet `
    -ActualPolicy $verifiedPolicy

$verification | Format-List

if (-not $verification.LegacyRulesMatch -or -not $verification.PolicyRulesMatch) {
    $token = $null
    throw "Read-back verification failed. The target backup is at $BackupPath."
}

$token = $null
Write-Host "Copy completed and both API surfaces match the source."
