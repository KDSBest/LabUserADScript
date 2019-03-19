Param 
(
    [parameter(Mandatory=$true)]
    [string]
    $SubscriptionId,
    [string]
    $UsernameFormat="LabUser{0:D2}",
    [string]
    $StartPassword="Password1!",
    [int]
    $UserCount=30,
    [string]
    $Location="West Europe",
    [string]
    $RoleDefinitionName="Contributor",
    [bool]
    $CreateCloudShellStorage=$true,
    [string]
    $CloudShellStorageSku="Standard_LRS"
)

# Check Admin Rights
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host "Administrator Rights are mendatory."
    return;
}

# Install Requirements
$adModule = Get-Module -Name AzureAD
if($adModule -eq $null)
{
    Write-Host "Install AzureAD Module."
    Install-Module AzureAD
}

$currentAzureContext = Get-AzureRmContext
if($currentAzureContext.Name -eq "Default")
{
    # Login Azure Account
    Login-AzureRmAccount
    $currentAzureContext = Get-AzureRmContext
}

Select-AzureRmSubscription -SubscriptionId $SubscriptionId

# Connect Azure AD
$tenantId = $currentAzureContext.Tenant.Id
$accountId = $currentAzureContext.Account.Id

Write-Host "Connect to AD with TenantId $($tenantId)"
$ad = Connect-AzureAD -TenantId $tenantId -AccountId $accountId
$domainName = $ad.TenantDomain

# Create Password Profile
$PasswordProfile = New-Object -TypeName Microsoft.Open.AzureAD.Model.PasswordProfile
$PasswordProfile.Password = $StartPassword

$locationForRgName = $Location.ToLower().Replace(" ", "")
$csRgName = "cloud-shell-storage-$($locationForRgName)"
$storageAcc = $null;
if($CreateCloudShellStorage)
{
    # Create Resource Group for Shell Storage
    $rg = Get-AzureRmResourceGroup -Name $csRgName -ErrorAction SilentlyContinue
    if($rg -eq $null)
    {
        Write-Host "Create Resource Group $($csRgName)"
        New-AzureRmResourceGroup -Location $Location -Name $displayName
    }
    else
    {
       Write-Host "Resource Group $($csRgName) already existed"
    }

    # Create Storage Account
    $subIdWithoutDashes = $SubscriptionId.ToLower().Replace("-", "");
    $subIdFormated = "$($subIdWithoutDashes.SubString(0, 12))x$($subIdWithoutDashes.SubString(12, 4))x$($subIdWithoutDashes.SubString(16, 3))"
    $saName = "csb$($subIdFormated)"
    $storageAcc = Get-AzureRmStorageAccount -ResourceGroupName $csRgName -Name $saName -ErrorAction SilentlyContinue
    if($storageAcc -eq $null)
    {
        Write-Host "Create Storage Account $($saName)"
        $storageAcc = New-AzureRmStorageAccount -Location $Location -Name $saName -ResourceGroupName $csRgName -SkuName $CloudShellStorageSku -Tag @{"ms-resource-usage"="azure-cloud-shell"}
    }
    else
    {
       Write-Host "Storage Account $($saName) already existed"
    }
}

for($i = 0; $i -lt $UserCount; $i++)
{
    $displayName = $UsernameFormat -f ($i + 1)
    $userPrincipalName = "$($displayName)@$($domainName)";

    # Create AD User
    $user = Get-AzureADUser -Filter "userPrincipalName eq '$($userPrincipalName)'"
    if($user -eq $null)
    {
        Write-Host "Create User $($userPrincipalName)"
        $user = New-AzureADUser -DisplayName $displayName -PasswordProfile $PasswordProfile -UserPrincipalName $userPrincipalName -AccountEnabled $true -MailNickName $displayName
    }
    else
    {
       Write-Host "User $($userPrincipalName) already existed"
    }

    # Create Resource Group
    $rg = Get-AzureRmResourceGroup -Name $displayName -ErrorAction SilentlyContinue
    if($rg -eq $null)
    {
        Write-Host "Create Resource Group $($displayName)"
        New-AzureRmResourceGroup -Location $Location -Name $displayName
    }
    else
    {
       Write-Host "Resource Group $($displayName) already existed"
    }

    # Give User Access to Resource Group
    $assignments = Get-AzureRmRoleAssignment -ResourceGroupName $displayName
    $hasAssignment = $false;
    for($j=0; $j -lt $assignments.Count;$j++)
    {
        if($assignments[$j].ObjectId -eq $user.ObjectId)
        {
            $hasAssignment = $true
            break
        }
    }

    if(!$hasAssignment)
    {
        Write-Host "Create Role Assignment $($RoleDefinitionName) for $($displayName) in Resource Group $($displayName)"
        New-AzureRmRoleAssignment -ObjectId $user.ObjectId -ResourceGroupName $displayName -RoleDefinitionName $RoleDefinitionName
    }
    else
    {
        Write-Host "Role Assignment $($RoleDefinitionName) for $($displayName) in Resource Group $($displayName) already existed"
    }

    if($CreateCloudShellStorage)
    {
        # Give User Access to Storage Account
        $assignments = Get-AzureRmRoleAssignment -ResourceGroupName $csRgName
        $hasAssignment = $false;
        for($j=0; $j -lt $assignments.Count;$j++)
        {
            if($assignments[$j].ObjectId -eq $user.ObjectId)
            {
                $hasAssignment = $true
                break
            }
        }

        if(!$hasAssignment)
        {
            Write-Host "Create Role Assignment $($RoleDefinitionName) for $($displayName) in Resource Group $($csRgName)"
            New-AzureRmRoleAssignment -ObjectId $user.ObjectId -ResourceGroupName $csRgName -RoleDefinitionName $RoleDefinitionName
        }
        else
        {
            Write-Host "Role Assignment $($RoleDefinitionName) for $($displayName) in Resource Group $($csRgName) already existed"
        }

        $context = $storageAcc

        $shareDisplayName = $userPrincipalName.ToLower().Replace("@", "-").Replace(".", "-")
        $prefix = "cs-$($shareDisplayName)"
        $shareId = (New-Guid).ToString("n").Substring(0, 16).ToLower()
        $fullShareName = "$($prefix)-$($shareId)"
        $share = Get-AzureStorageShare -Prefix $prefix -Context $storageAcc.Context
        if($share -eq $null)
        {
            Write-Host "Create Storage Share $($fullShareName)"
            New-AzureStorageShare -Name $fullShareName -Context $storageAcc.Context
        }
        else
        {
            Write-Host "Storage Share $($prefix) already existed"
        }
    }
}
