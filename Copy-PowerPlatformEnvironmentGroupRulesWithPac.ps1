[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory)]
    [guid]$SourceGroupId,

    [Parameter(Mandatory)]
    [guid]$TargetGroupId,

    [string]$PacPath = "pac",

    [ValidateRange(0, 1000)]
    [int]$PacProfileIndex = 0,

    [switch]$Apply,

    [string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($SourceGroupId -eq $TargetGroupId) {
    throw "SourceGroupId and TargetGroupId must be different."
}

$pacCommand = Get-Command $PacPath -ErrorAction SilentlyContinue
if ($null -ne $pacCommand) {
    $PacPath = $pacCommand.Source
}
elseif (-not (Test-Path -LiteralPath $PacPath -PathType Leaf)) {
    throw "Power Platform CLI was not found at '$PacPath'."
}

if ([IO.Path]::GetFileName($PacPath) -in @("pac.cmd", "pac.launcher.exe")) {
    $pacRoot = Split-Path $PacPath
    $resolvedPac = Get-ChildItem `
        -LiteralPath $pacRoot `
        -Directory `
        -Filter "Microsoft.PowerApps.CLI.*" |
        Sort-Object Name -Descending |
        ForEach-Object {
            Join-Path $_.FullName "tools\pac.exe"
        } |
        Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        } |
        Select-Object -First 1

    if (-not $resolvedPac) {
        throw "The installed PAC runtime couldn't be resolved from '$pacRoot'."
    }
    $PacPath = $resolvedPac
}

$pacDirectory = Split-Path $PacPath
$newtonsoftPath = Join-Path $pacDirectory "Newtonsoft.Json.dll"
if (-not (Test-Path -LiteralPath $newtonsoftPath)) {
    throw "PAC's Newtonsoft.Json.dll was not found beside '$PacPath'."
}
[void][Reflection.Assembly]::LoadFrom($newtonsoftPath)

function Invoke-PacRaw {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new($PacPath)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout.Trim()
        StdErr   = $stderr.Trim()
    }

    if (-not $AllowFailure -and $result.ExitCode -ne 0) {
        $message = @($result.StdErr, $result.StdOut) |
            Where-Object { $_ } |
            Join-String -Separator [Environment]::NewLine
        throw "PAC command failed: $message"
    }

    return $result
}

function ConvertTo-PacJson {
    param(
        [AllowNull()]
        [object]$InputObject,

        [switch]$AsArray
    )

    if ($AsArray) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in @($InputObject)) {
            $items.Add($item)
        }
        $value = $items.ToArray()
    }
    else {
        $value = $InputObject
    }

    $stringWriter = [IO.StringWriter]::new(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $jsonWriter = [Newtonsoft.Json.JsonTextWriter]::new($stringWriter)
    $jsonWriter.Formatting = [Newtonsoft.Json.Formatting]::None
    $jsonWriter.QuoteChar = [char]"'"

    try {
        $standardJson = ConvertTo-Json `
            -InputObject $value `
            -Depth 100 `
            -Compress
        $token = [Newtonsoft.Json.Linq.JToken]::Parse($standardJson)
        $token.WriteTo($jsonWriter)
        $jsonWriter.Flush()
        return $stringWriter.ToString()
    }
    finally {
        $jsonWriter.Dispose()
        $stringWriter.Dispose()
    }
}

function ConvertFrom-PacJson {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Result
    )

    if (-not $Result.StdOut -or $Result.StdOut -eq "null") {
        return $null
    }

    return $Result.StdOut | ConvertFrom-Json
}

function Get-RuleSet {
    param([guid]$GroupId)

    $result = Invoke-PacRaw -Arguments @(
        "governance", "get-rule-set",
        "--group-id", $GroupId.ToString(),
        "--json"
    )
    $response = ConvertFrom-PacJson -Result $result
    if ($null -eq $response -or @($response.value).Count -eq 0) {
        return $null
    }
    if (@($response.value).Count -ne 1) {
        throw "Environment group $GroupId returned $(@($response.value).Count) rule sets; expected at most one."
    }
    return @($response.value)[0]
}

function Get-GroupPolicyAssignment {
    param([guid]$GroupId)

    $result = Invoke-PacRaw -Arguments @(
        "governance", "list-rule-assignments-by-environment-group-id",
        "--environment-group-id", $GroupId.ToString(),
        "--include-rule-set-counts", "true",
        "--json"
    )
    $response = ConvertFrom-PacJson -Result $result
    $assignments = @(
        if ($null -ne $response) {
            $response.value
        }
    )
    if ($assignments.Count -gt 1) {
        throw "Environment group $GroupId returned $($assignments.Count) policy assignments; expected at most one."
    }
    return $assignments | Select-Object -First 1
}

function Get-Policy {
    param([string]$PolicyId)

    $result = Invoke-PacRaw -Arguments @(
        "governance", "get-rule-based-policy-by-id",
        "--policy-id", $PolicyId,
        "--json"
    )
    return ConvertFrom-PacJson -Result $result
}

function Get-PolicyAssignments {
    param([string]$PolicyId)

    $result = Invoke-PacRaw -Arguments @(
        "governance", "list-rule-assignments-by-policy-id",
        "--policy-id", $PolicyId,
        "--include-rule-set-counts", "true",
        "--json"
    )
    $response = ConvertFrom-PacJson -Result $result
    if ($null -eq $response) {
        return @()
    }
    return @($response.value)
}

function Get-LegacyRuleSummary {
    param([AllowNull()][object]$RuleSet)

    if ($null -eq $RuleSet) {
        return @()
    }

    return @(
        $RuleSet.parameters |
            ForEach-Object {
                "{0}/{1} ({2} values)" -f `
                    $_.type, `
                    $_.resourceType, `
                    @($_.value).Count
            } |
            Sort-Object
    )
}

function Get-PolicyRuleSummary {
    param([AllowNull()][object]$Policy)

    if ($null -eq $Policy) {
        return @()
    }

    return @($Policy.ruleSets | ForEach-Object id | Sort-Object)
}

function ConvertTo-CanonicalNode {
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [string] -or $InputObject.GetType().IsValueType) {
        return $InputObject
    }
    if ($InputObject -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in ($InputObject.Keys | Sort-Object)) {
            $ordered[$key] = ConvertTo-CanonicalNode $InputObject[$key]
        }
        return [pscustomobject]$ordered
    }
    if ($InputObject -is [Collections.IEnumerable]) {
        return @(
            @(
                foreach ($item in $InputObject) {
                    ConvertTo-CanonicalNode $item
                }
            ) |
                Sort-Object {
                    $_ | ConvertTo-Json -Depth 100 -Compress
                }
        )
    }

    $result = [ordered]@{}
    foreach ($property in (
            $InputObject.PSObject.Properties |
                Where-Object MemberType -in NoteProperty, Property |
                Sort-Object Name
        )) {
        $result[$property.Name] = ConvertTo-CanonicalNode $property.Value
    }
    return [pscustomobject]$result
}

function Get-CanonicalJson {
    param([AllowNull()][object]$InputObject)

    ConvertTo-CanonicalNode $InputObject |
        ConvertTo-Json -Depth 100 -Compress
}

function Normalize-LegacyRules {
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

function Normalize-PolicyRules {
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

function Test-PathInsideGitWorktree {
    param([string]$Path)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return $false
    }
    $directory = Split-Path -Parent $Path
    if (-not $directory -or -not (Test-Path $directory)) {
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
        $path = if ([IO.Path]::IsPathRooted($BackupPath)) {
            [IO.Path]::GetFullPath($BackupPath)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path (Get-Location) $BackupPath))
        }
    }
    else {
        $root = if ($IsWindows -and $env:LOCALAPPDATA) {
            Join-Path $env:LOCALAPPDATA "PowerPlatformEnvironmentGroupRuleCopier\Backups"
        }
        else {
            Join-Path $HOME ".powerplatform-environment-group-rule-copier/backups"
        }
        $path = Join-Path $root (
            "environment-group-rules-pac-{0}-{1}.backup.json" -f `
                (Get-Date -Format "yyyyMMdd-HHmmss"), `
                ([guid]::NewGuid().ToString("N").Substring(0, 8))
        )
    }

    $parent = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-PathInsideGitWorktree -Path $path) {
        throw "BackupPath must be outside a Git worktree."
    }
    return $path
}

function Protect-BackupFile {
    param([string]$Path)

    if ($IsWindows) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetOwner($identity)
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $identity,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow
            )
        )
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    else {
        [IO.File]::SetUnixFileMode(
            $Path,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        )
    }
}

$activeProfileIndex = $null
$profileChanged = $false

try {
    $governanceHelp = Invoke-PacRaw -Arguments @("governance", "help")
    if ($governanceHelp.StdOut -notmatch "create-rule-set") {
        throw "This PAC version doesn't expose the required governance commands. PAC 2.12.2 or later is recommended."
    }

    if ($PacProfileIndex -gt 0) {
        $authList = Invoke-PacRaw -Arguments @("auth", "list")
        foreach ($line in ($authList.StdOut -split "`r?`n")) {
            if ($line -match "^\[(\d+)\]\s+\*") {
                $activeProfileIndex = [int]$matches[1]
                break
            }
        }

        if ($activeProfileIndex -ne $PacProfileIndex) {
            Invoke-PacRaw -Arguments @(
                "auth", "select",
                "--index", $PacProfileIndex.ToString()
            ) | Out-Null
            $profileChanged = $true
        }
    }

    $sourceRuleSet = Get-RuleSet -GroupId $SourceGroupId
    $targetRuleSet = Get-RuleSet -GroupId $TargetGroupId
    $sourceAssignment = Get-GroupPolicyAssignment -GroupId $SourceGroupId
    $targetAssignment = Get-GroupPolicyAssignment -GroupId $TargetGroupId
    $sourcePolicy = if ($null -ne $sourceAssignment) {
        Get-Policy -PolicyId $sourceAssignment.policyId
    }
    else {
        $null
    }
    $targetPolicy = if ($null -ne $targetAssignment) {
        Get-Policy -PolicyId $targetAssignment.policyId
    }
    else {
        $null
    }
    $targetPolicyAssignments = @(
        if ($null -ne $targetPolicy) {
            Get-PolicyAssignments -PolicyId $targetPolicy.id
        }
    )

    [pscustomobject]@{
        SourceGroupId           = $SourceGroupId
        TargetGroupId           = $TargetGroupId
        LegacyRules             = Get-LegacyRuleSummary $sourceRuleSet
        PolicyRules             = Get-PolicyRuleSummary $sourcePolicy
        TargetPolicyAssignments = $targetPolicyAssignments.Count
        Apply                   = [bool]$Apply
        Transport               = "PAC governance"
    } | Format-List

    if (-not $Apply) {
        Write-Host "Plan only. Re-run with -Apply to write the target group."
        return
    }

    if (-not $PSCmdlet.ShouldProcess(
            "environment group $TargetGroupId",
            "copy exposed governance configuration from $SourceGroupId through PAC"
        )) {
        Write-Host "No changes made."
        return
    }

    if ($targetPolicyAssignments.Count -gt 1) {
        throw "PAC one-off mode can't safely replace a policy with multiple assignments because PAC doesn't expose assignment deletion."
    }

    $BackupPath = Resolve-BackupPath
    $backup = @{
        capturedAtUtc    = (Get-Date).ToUniversalTime().ToString("o")
        groupId          = $TargetGroupId
        ruleSet          = $targetRuleSet
        policy           = $targetPolicy
        policyAssignments = $targetPolicyAssignments
        transport        = "PAC governance"
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

    if ($null -ne $sourceRuleSet) {
        $ruleArguments = @(
            "governance",
            $(if ($null -eq $targetRuleSet) { "create-rule-set" } else { "update-rule-set" })
        )
        if ($null -eq $targetRuleSet) {
            $ruleArguments += @("--group-id", $TargetGroupId.ToString())
        }
        else {
            $ruleArguments += @(
                "--rule-set-id", $targetRuleSet.id,
                "--id", $targetRuleSet.id
            )
        }
        $ruleArguments += @(
            "--last-modified", (Get-Date).ToUniversalTime().ToString("o"),
            "--parameters", (ConvertTo-PacJson $sourceRuleSet.parameters -AsArray),
            "--environment-filter-type", "Include",
            "--environment-filter-values", (
                ConvertTo-PacJson @(
                    @{
                        id   = $TargetGroupId.ToString()
                        type = "EnvironmentGroup"
                    }
                ) -AsArray
            ),
            "--json"
        )
        Invoke-PacRaw -Arguments $ruleArguments | Out-Null
    }

    if ($null -ne $sourcePolicy) {
        if ($null -eq $targetPolicy) {
            $createdPolicy = ConvertFrom-PacJson -Result (
                Invoke-PacRaw -Arguments @(
                    "governance", "create-rule-based-policy",
                    "--name", "$($sourcePolicy.name) (copy)",
                    "--rule-sets", (
                        ConvertTo-PacJson $sourcePolicy.ruleSets -AsArray
                    ),
                    "--json"
                )
            )
            try {
                Invoke-PacRaw -Arguments @(
                    "governance",
                    "create-enviornment-group-rule-based-assignment",
                    "--policy-id", $createdPolicy.id,
                    "--group-id", $TargetGroupId.ToString(),
                    "--assignment-overrides", "[]",
                    "--json"
                ) | Out-Null
            }
            catch {
                Write-Warning "PAC created policy $($createdPolicy.id) but couldn't assign it. PAC has no policy-delete command; remove the orphan through PPAC or the REST API."
                throw
            }
        }
        else {
            Invoke-PacRaw -Arguments @(
                "governance", "update-rule-based-policy-by-id",
                "--policy-id", $targetPolicy.id,
                "--name", $targetPolicy.name,
                "--rule-sets", (
                    ConvertTo-PacJson $sourcePolicy.ruleSets -AsArray
                ),
                "--json"
            ) | Out-Null
        }
    }

    $verifiedRuleSet = Get-RuleSet -GroupId $TargetGroupId
    $verifiedAssignment = Get-GroupPolicyAssignment -GroupId $TargetGroupId
    $verifiedPolicy = if ($null -ne $verifiedAssignment) {
        Get-Policy -PolicyId $verifiedAssignment.policyId
    }
    else {
        $null
    }

    $legacyMatch = (
        Get-CanonicalJson (Normalize-LegacyRules $sourceRuleSet)
    ) -eq (
        Get-CanonicalJson (Normalize-LegacyRules $verifiedRuleSet)
    )
    $policyMatch = (
        Get-CanonicalJson (Normalize-PolicyRules $sourcePolicy)
    ) -eq (
        Get-CanonicalJson (Normalize-PolicyRules $verifiedPolicy)
    )

    [pscustomobject]@{
        LegacyRulesMatch = $legacyMatch
        PolicyRulesMatch = $policyMatch
    } | Format-List

    if (-not $legacyMatch -or -not $policyMatch) {
        throw "Read-back verification failed. The target backup is at $BackupPath."
    }

    Write-Host "PAC copy completed and both API surfaces match the source."
}
finally {
    if (
        $profileChanged -and
        $null -ne $activeProfileIndex
    ) {
        try {
            Invoke-PacRaw -Arguments @(
                "auth", "select",
                "--index", $activeProfileIndex.ToString()
            ) | Out-Null
        }
        catch {
            Write-Warning "Failed to restore PAC auth profile index $activeProfileIndex."
        }
    }
}
