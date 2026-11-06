[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string[]]$SubscriptionIds,

    [Parameter()]
    [switch]$AllSubscriptions,

    [Parameter()]
    [string[]]$RepositoryScopes,

    [Parameter()]
    [string]$AssigneeObjectId,

    [Parameter()]
    [string]$AssigneeAppId,

    [Parameter()]
    [switch]$SkipBlobRole,

    [Parameter()]
    [ValidateRange(0, 600)]
    [int]$PropagationWaitSeconds = 30
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Role definitions (edit here if Veeam's documentation changes)
# ----------------------------------------------------------------------------
$PrivateEndpointRoleName = 'Veeam Backup for Azure - v9 Private Endpoint Approval'
$BlobRoleName            = 'Veeam Backup for Azure - v9 Blob Repository Access'

$PrivateEndpointActions = @(
    'Microsoft.DBforPostgreSQL/serverGroupsv2/privateEndpointConnectionsApproval/action'
    'Microsoft.DBforPostgreSQL/serverGroupsv2/privateEndpointConnections/read'
    'Microsoft.DBforPostgreSQL/serverGroupsv2/privateEndpointConnections/write'
    'Microsoft.DocumentDB/databaseAccounts/PrivateEndpointConnectionsApproval/action'
    'Microsoft.DocumentDB/databaseAccounts/privateEndpointConnections/read'
    'Microsoft.DocumentDB/databaseAccounts/privateEndpointConnections/write'
    'Microsoft.Sql/ManagedInstances/privateEndpointConnections/read'
    'Microsoft.Sql/ManagedInstances/privateEndpointConnections/write'
    'Microsoft.Sql/servers/privateEndpointConnections/read'
    'Microsoft.Sql/servers/privateEndpointConnections/write'
    'Microsoft.Sql/servers/PrivateEndpointConnectionsApproval/action'
)

$BlobActions = @(
    'Microsoft.Storage/storageAccounts/blobServices/containers/delete'
)

$BlobDataActions = @(
    'Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action'
    'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action'
    'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete'
    'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'
    'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "    [SKIP] $Message" -ForegroundColor Yellow }

function Confirm-Modules {
    foreach ($m in 'Az.Accounts', 'Az.Resources') {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            throw "Required module '$m' is not installed. Run: Install-Module Az -Scope CurrentUser"
        }
        Import-Module $m -ErrorAction Stop
    }
}

function Set-CustomRole {
    <#
        Creates the role if missing, otherwise updates it in place.
        Uses a temp JSON file so DataActions and multiple AssignableScopes are handled reliably.
        Returns $true if the role was newly created.
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Description,
        [string[]]$Actions,
        [string[]]$DataActions = @(),
        [string[]]$AssignableScopes
    )

    $existing = Get-AzRoleDefinition -Name $Name -ErrorAction SilentlyContinue

    $def = [ordered]@{
        Name             = $Name
        IsCustom         = $true
        Description      = $Description
        Actions          = @($Actions)
        NotActions       = @()
        DataActions      = @($DataActions)
        NotDataActions   = @()
        AssignableScopes = @($AssignableScopes)
    }
    if ($existing) { $def['Id'] = $existing.Id }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("veeam-role-{0}.json" -f [guid]::NewGuid())
    try {
        $def | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8

        if ($existing) {
            if ($PSCmdlet.ShouldProcess($Name, 'Update custom role definition')) {
                Set-AzRoleDefinition -InputFile $tmp | Out-Null
                Write-Ok "Updated role definition '$Name'"
            }
            return $false
        }
        else {
            if ($PSCmdlet.ShouldProcess($Name, 'Create custom role definition')) {
                New-AzRoleDefinition -InputFile $tmp | Out-Null
                Write-Ok "Created role definition '$Name'"
                return $true
            }
            return $false
        }
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Add-RoleAssignmentSafe {
    <#
        Idempotent assignment with retry (new role definitions can take a while to propagate).
    #>
    [CmdletBinding()]
    param(
        [string]$ObjectId,
        [string]$RoleName,
        [string]$Scope
    )

    $current = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleName -Scope $Scope -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $Scope }

    if ($current) {
        Write-Skip "'$RoleName' already assigned at $Scope"
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Scope, "Assign '$RoleName' to $ObjectId")) { return }

    $maxAttempts = 6
    for ($i = 1; $i -le $maxAttempts; $i++) {
        try {
            New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleName -Scope $Scope | Out-Null
            Write-Ok "Assigned '$RoleName' at $Scope"
            return
        }
        catch {
            if ($i -eq $maxAttempts) { throw }
            Write-Warning "Assignment attempt $i failed ($($_.Exception.Message.Split("`n")[0])). Retrying in 15s..."
            Start-Sleep -Seconds 15
        }
    }
}

# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------
Write-Step 'Validating input'
Confirm-Modules

if (-not $AssigneeObjectId -and -not $AssigneeAppId) {
    throw 'Provide either -AssigneeObjectId or -AssigneeAppId.'
}

if (-not $SkipBlobRole) {
    if (-not $RepositoryScopes -or $RepositoryScopes.Count -eq 0) {
        throw 'Provide -RepositoryScopes for the blob role, or use -SkipBlobRole.'
    }
    foreach ($s in $RepositoryScopes) {
        if ($s -notmatch '^/subscriptions/[0-9a-fA-F-]{36}(/resourceGroups/[^/]+)?(/providers/Microsoft\.Storage/storageAccounts/[^/]+)?$') {
            throw "Invalid repository scope: '$s'. Use a storage account or resource group resource ID."
        }
    }
}

# ----------------------------------------------------------------------------
# Connect and resolve assignee
# ----------------------------------------------------------------------------
Write-Step 'Checking Azure connection'
$ctx = Get-AzContext
if (-not $ctx) {
    # Newer Az.Accounts versions show an interactive tenant/subscription picker at sign-in.
    # Turn it off for this session only so the script never prompts for a subscription.
    try { Update-AzConfig -LoginExperienceV2 Off -Scope Process | Out-Null } catch { }
    Connect-AzAccount | Out-Null
    $ctx = Get-AzContext
}
Write-Ok "Signed in as $($ctx.Account.Id)"

# Resolve subscriptions without prompting:
#   -SubscriptionIds   -> use exactly those
#   -AllSubscriptions  -> every enabled subscription in the current tenant
#   neither            -> the subscription in the current Az context
if ($SubscriptionIds -and $AllSubscriptions) {
    throw 'Use either -SubscriptionIds or -AllSubscriptions, not both.'
}

if ($AllSubscriptions) {
    $SubscriptionIds = @(Get-AzSubscription -TenantId $ctx.Tenant.Id |
        Where-Object { $_.State -eq 'Enabled' } |
        Select-Object -ExpandProperty Id)
    if (-not $SubscriptionIds) { throw 'No enabled subscriptions found in the current tenant.' }
}
elseif (-not $SubscriptionIds) {
    if ($ctx.Subscription -and $ctx.Subscription.Id) {
        $SubscriptionIds = @($ctx.Subscription.Id)
    }
    else {
        $available = @(Get-AzSubscription -TenantId $ctx.Tenant.Id | Where-Object { $_.State -eq 'Enabled' })
        if ($available.Count -eq 1) {
            $SubscriptionIds = @($available[0].Id)
        }
        else {
            throw 'No default subscription in the current context. Run Set-AzContext, or pass -SubscriptionIds / -AllSubscriptions.'
        }
    }
}

Write-Ok ("Subscriptions in scope: {0}" -f ($SubscriptionIds -join ', '))

# Role definitions are created within one subscription context
Set-AzContext -Subscription $SubscriptionIds[0] | Out-Null

if (-not $AssigneeObjectId) {
    Write-Step "Resolving service principal for AppId $AssigneeAppId"
    $sp = Get-AzADServicePrincipal -ApplicationId $AssigneeAppId -ErrorAction Stop
    if (-not $sp) { throw "No service principal found for AppId $AssigneeAppId" }
    $AssigneeObjectId = $sp.Id
    Write-Ok "Object ID: $AssigneeObjectId ($($sp.DisplayName))"
}

# ----------------------------------------------------------------------------
# Role 1: Private endpoint approval (subscription scope)
# ----------------------------------------------------------------------------
Write-Step "Role 1: $PrivateEndpointRoleName"
$peScopes = $SubscriptionIds | ForEach-Object { "/subscriptions/$_" }

$peCreated = Set-CustomRole `
    -Name $PrivateEndpointRoleName `
    -Description 'Veeam Plug-in for Microsoft Azure v9: create and approve private endpoint connections for Azure SQL, SQL MI, Cosmos DB, and PostgreSQL.' `
    -Actions $PrivateEndpointActions `
    -AssignableScopes $peScopes

# ----------------------------------------------------------------------------
# Role 2: Blob repository access (repository scope)
# ----------------------------------------------------------------------------
$blobCreated = $false
if (-not $SkipBlobRole) {
    Write-Step "Role 2: $BlobRoleName"
    $blobCreated = Set-CustomRole `
        -Name $BlobRoleName `
        -Description 'Veeam Plug-in for Microsoft Azure v9: blob read/write/delete and user delegation key for the backup repository storage account.' `
        -Actions $BlobActions `
        -DataActions $BlobDataActions `
        -AssignableScopes $RepositoryScopes
}

# ----------------------------------------------------------------------------
# Propagation wait (only when a role was just created)
# ----------------------------------------------------------------------------
if (($peCreated -or $blobCreated) -and $PropagationWaitSeconds -gt 0 -and -not $WhatIfPreference) {
    Write-Step "Waiting $PropagationWaitSeconds seconds for role definition propagation"
    Start-Sleep -Seconds $PropagationWaitSeconds
}

# ----------------------------------------------------------------------------
# Assignments
# ----------------------------------------------------------------------------
Write-Step 'Assigning private endpoint role (per subscription)'
foreach ($scope in $peScopes) {
    Add-RoleAssignmentSafe -ObjectId $AssigneeObjectId -RoleName $PrivateEndpointRoleName -Scope $scope
}

if (-not $SkipBlobRole) {
    Write-Step 'Assigning blob repository role (per repository scope)'
    foreach ($scope in $RepositoryScopes) {
        Add-RoleAssignmentSafe -ObjectId $AssigneeObjectId -RoleName $BlobRoleName -Scope $scope
    }
}

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
if (-not $WhatIfPreference) {
    Write-Step 'Verification'
    $names = @($PrivateEndpointRoleName)
    if (-not $SkipBlobRole) { $names += $BlobRoleName }

    $report = foreach ($sub in $SubscriptionIds) {
        Set-AzContext -Subscription $sub | Out-Null
        Get-AzRoleAssignment -ObjectId $AssigneeObjectId |
            Where-Object { $_.RoleDefinitionName -in $names } |
            Select-Object RoleDefinitionName, Scope, DisplayName
    }

    if ($report) {
        $report | Sort-Object RoleDefinitionName, Scope -Unique | Format-Table -AutoSize
    }
    else {
        Write-Warning 'No matching assignments found yet. Role assignments can take a few minutes to appear.'
    }

    Write-Host "`nDone. Allow a few minutes for data-plane permissions to propagate before upgrading the appliance or running the first backup." -ForegroundColor Green
}
else {
    Write-Host "`n-WhatIf run complete. No changes were made." -ForegroundColor Yellow
}
