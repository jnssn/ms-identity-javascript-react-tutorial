
[CmdletBinding()]
param(
    [Parameter(Mandatory=$True, HelpMessage='Tenant ID (This is a GUID which represents the "Directory ID" of the AzureAD tenant into which you want to create the apps')]
    [string] $tenantId,
    [Parameter(Mandatory=$False, HelpMessage='Azure environment to use while running the script (it defaults to AzureCloud)')]
    [string] $azureEnvironmentName
)

<#
 This script creates the Azure AD applications needed for this sample and updates the configuration files
 for the visual Studio projects from the data in the Azure AD applications.

 Before running this script you need to install the Graph cmdlets as an administrator. 
 For this:
 1) Run Powershell as an administrator
 2) in the PowerShell window, type: Install-Module Microsoft.Graph.Applications

 There are four ways to run this script. For more information, read the AppCreationScripts.md file in the same folder as this script.
#>

#OBSOLETE after migration to Graph API
# Create a password that can be used as an application key
Function ComputePassword
{
    $aesManaged = New-Object "System.Security.Cryptography.AesManaged"
    $aesManaged.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aesManaged.Padding = [System.Security.Cryptography.PaddingMode]::Zeros
    $aesManaged.BlockSize = 128
    $aesManaged.KeySize = 256
    $aesManaged.GenerateKey()
    return [System.Convert]::ToBase64String($aesManaged.Key)
}

# Create an application key
# See https://www.sabin.io/blog/adding-an-azure-active-directory-application-and-key-using-powershell/
Function CreateAppKey([DateTime] $fromDate, [double] $durationInMonths)
{
    $key = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphPasswordCredential

    $key.StartDateTime = $fromDate
    $key.EndDateTime = $fromDate.AddMonths($durationInMonths)
    $key.KeyId = (New-Guid).ToString()
    $key.DisplayName = "app secret"

    return $key
}

# Adds the requiredAccesses (expressed as a pipe separated string) to the requiredAccess structure
# The exposed permissions are in the $exposedPermissions collection, and the type of permission (Scope | Role) is 
# described in $permissionType
Function AddResourcePermission($requiredAccess, `
                               $exposedPermissions, [string]$requiredAccesses, [string]$permissionType)
{
    foreach($permission in $requiredAccesses.Trim().Split("|"))
    {
        foreach($exposedPermission in $exposedPermissions)
        {
            if ($exposedPermission.Value -eq $permission)
                {
                $resourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess
                $resourceAccess.Type = $permissionType # Scope = Delegated permissions | Role = Application permissions
                $resourceAccess.Id = $exposedPermission.Id # Read directory data
                $requiredAccess.ResourceAccess += $resourceAccess
                }
        }
    }
}

#
# Example: GetRequiredPermissions "Microsoft Graph"  "Graph.Read|User.Read"
# See also: http://stackoverflow.com/questions/42164581/how-to-configure-a-new-azure-ad-application-through-powershell
Function GetRequiredPermissions([string] $applicationDisplayName, [string] $requiredDelegatedPermissions, [string]$requiredApplicationPermissions, $servicePrincipal)
{
    # If we are passed the service principal we use it directly, otherwise we find it from the display name (which might not be unique)
    if ($servicePrincipal)
    {
        $sp = $servicePrincipal
    }
    else
    {
        $sp = Get-MgServicePrincipal -Filter "DisplayName eq '$applicationDisplayName'"
    }
    $appid = $sp.AppId
    $requiredAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess
    $requiredAccess.ResourceAppId = $appid 
    $requiredAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess]

    # $sp.Oauth2Permissions | Select Id,AdminConsentDisplayName,Value: To see the list of all the Delegated permissions for the application:
    if ($requiredDelegatedPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.Oauth2PermissionScopes -requiredAccesses $requiredDelegatedPermissions -permissionType "Scope"
    }
    
    # $sp.AppRoles | Select Id,AdminConsentDisplayName,Value: To see the list of all the Application permissions for the application
    if ($requiredApplicationPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.AppRoles -requiredAccesses $requiredApplicationPermissions -permissionType "Role"
    }
    return $requiredAccess
}


Function ReplaceInLine([string] $line, [string] $key, [string] $value)
{
    $index = $line.IndexOf($key)
    if ($index -ige 0)
    {
        $index2 = $index+$key.Length
        $line = $line.Substring(0, $index) + $value + $line.Substring($index2)
    }
    return $line
}

Function ReplaceInTextFile([string] $configFilePath, [System.Collections.HashTable] $dictionary)
{
    $lines = Get-Content $configFilePath
    $index = 0
    while($index -lt $lines.Length)
    {
        $line = $lines[$index]
        foreach($key in $dictionary.Keys)
        {
            if ($line.Contains($key))
            {
                $lines[$index] = ReplaceInLine $line $key $dictionary[$key]
            }
        }
        $index++
    }

    Set-Content -Path $configFilePath -Value $lines -Force
}
<#.Description
   This function creates a new Azure AD scope (OAuth2Permission) with default and provided values
#>  
Function CreateScope( [string] $value, [string] $userConsentDisplayName, [string] $userConsentDescription, [string] $adminConsentDisplayName, [string] $adminConsentDescription)
{
    $scope = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphPermissionScope
    $scope.Id = New-Guid
    $scope.Value = $value
    $scope.UserConsentDisplayName = $userConsentDisplayName
    $scope.UserConsentDescription = $userConsentDescription
    $scope.AdminConsentDisplayName = $adminConsentDisplayName
    $scope.AdminConsentDescription = $adminConsentDescription
    $scope.IsEnabled = $true
    $scope.Type = "User"
    return $scope
}

<#.Description
   This function creates a new Azure AD AppRole with default and provided values
#>  
Function CreateAppRole([string] $types, [string] $name, [string] $description)
{
    $appRole = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphAppRole
    $appRole.AllowedMemberTypes = New-Object System.Collections.Generic.List[string]
    $typesArr = $types.Split(',')
    foreach($type in $typesArr)
    {
        $appRole.AllowedMemberTypes.Add($type);
    }
    $appRole.DisplayName = $name
    $appRole.Id = New-Guid
    $appRole.IsEnabled = $true
    $appRole.Description = $description
    $appRole.Value = $name;
    return $appRole
}

# Pre-requisites
if ($null -eq (Get-Module -ListAvailable -Name "Microsoft.Graph.Applications")) {
    Install-Module "Microsoft.Graph.Applications" -Scope CurrentUser 
}

Import-Module Microsoft.Graph.Applications

Set-Content -Value "<html><body><table>" -Path createdApps.html
Add-Content -Value "<thead><tr><th>Application</th><th>AppId</th><th>Url in the Azure portal</th></tr></thead><tbody>" -Path createdApps.html

$ErrorActionPreference = "Stop"

Function ConfigureApplications
{
    <#.Description
       This function creates the Azure AD applications for the sample in the provided Azure AD tenant and updates the
       configuration files in the client and service project  of the visual studio solution (App.Config and Web.Config)
       so that they are consistent with the Applications parameters
    #> 

    # Connect to the Microsoft Graph API, non-interactive is not supported for the moment (Oct 2021)
    if (!$azureEnvironmentName)
    {
        $azureEnvironmentName = "Global"
    }

    Write-Host "Connecting Microsoft Graph"
    Connect-MgGraph -TenantId $TenantId -Scopes "Application.ReadWrite.All" -Environment $azureEnvironmentName


   # Create the service AAD application
   Write-Host "Creating the AAD application (msal-node-api-acrs)"
   # Get a 6 months application key for the service Application
   $fromDate = [DateTime]::Now;
   $key = CreateAppKey -fromDate $fromDate -durationInMonths 6
   
   
   # create the application 
   $serviceAadApplication = New-MgApplication -DisplayName "msal-node-api-acrs" `
                                                       -Web `
                                                       @{ `
                                                           RedirectUris = "http://localhost:5000/admin/redirect"; `
                                                           HomePageUrl = "http://localhost:5000/admin/home"; `

                                                           ImplicitGrantSettings = @{EnableIdTokenIssuance=$true;EnableAccessTokenIssuance=$false} ` 
 
                                                         } `
                                                       -SignInAudience AzureADMyOrg `
                                                       #-PublicClient $False
    #add password to the application
    $pwdCredential = Add-MgApplicationPassword -ApplicationId $serviceAadApplication.Id -PasswordCredential $key
    $serviceAppKey = $pwdCredential.SecretText
    $serviceIdentifierUri = 'api://'+$serviceAadApplication.AppId
    Update-MgApplication -ApplicationId $serviceAadApplication.Id -IdentifierUris @($serviceIdentifierUri)
    
    # create the service principal of the newly created application 
    $currentAppId = $serviceAadApplication.AppId
    $serviceServicePrincipal = New-MgServicePrincipal -AppId $currentAppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}

    # add the user running the script as an app owner if needed
    $owner = Get-MgApplicationOwner -ApplicationId $serviceAadApplication.Id
    if ($owner -eq $null)
    { 
        New-MgApplicationOwnerByRef -ApplicationId $serviceAadApplication.Id  -BodyParameter = @{"@odata.id" = "htps://graph.microsoft.com/v1.0/directoryObjects/$user.ObjectId"}
        Write-Host "'$($user.UserPrincipalName)' added as an application owner to app '$($serviceServicePrincipal.DisplayName)'"
    }
    
    # rename the user_impersonation scope if it exists to match the readme steps or add a new scope
    $scopes = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphPermissionScope]
   
    # delete default scope i.e. User_impersonation
    $scope = $serviceAadApplication.Api.Oauth2PermissionScopes | Where-Object { $_.Value -eq "User_impersonation" }
    if($scope -ne $null)
    {
        # disable the scope
        $scope.IsEnabled = $false
        Update-MgApplication -ApplicationId $serviceAadApplication.Id -Api @{Oauth2PermissionScopes = $scopes}

        # clear the scope
        $scopes.Clear()
        Update-MgApplication -ApplicationId $serviceAadApplication.Id -Api @{Oauth2PermissionScopes = $scopes}
    }
    if ($scopes.Count -ge 0) 
    {
        $scope = CreateScope -value access_as_user  `
        -userConsentDisplayName "Access msal-node-api-acrs"  `
        -userConsentDescription "Allow the application to access msal-node-api-acrs on your behalf."  `
        -adminConsentDisplayName "Access msal-node-api-acrs"  `
        -adminConsentDescription "Allows the app to have the same access to information in the directory on behalf of the signed-in user."
            
        $scopes.Add($scope)
    
    }
     
    # add/update scopes
    Update-MgApplication -ApplicationId $serviceAadApplication.Id -Api @{Oauth2PermissionScopes = $scopes}
    Write-Host "Done creating the service application (msal-node-api-acrs)"

    # URL of the AAD application in the Azure portal
    # Future? $servicePortalUrl = "https://portal.azure.com/#@"+$tenantName+"/blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/"+$serviceAadApplication.AppId+"/objectId/"+$serviceAadApplication.ObjectId+"/isMSAApp/"
    $servicePortalUrl = "https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/CallAnAPI/appId/"+$serviceAadApplication.AppId+"/objectId/"+$serviceAadApplication.ObjectId+"/isMSAApp/"
    Add-Content -Value "<tr><td>service</td><td>$currentAppId</td><td><a href='$servicePortalUrl'>msal-node-api-acrs</a></td></tr>" -Path createdApps.html
    $requiredResourcesAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]

    
    # Add Required Resources Access (from 'service' to 'Microsoft Graph')
    Write-Host "Getting access from 'service' to 'Microsoft Graph'"
    $requiredPermissions = GetRequiredPermissions -applicationDisplayName "Microsoft Graph" `
        -requiredDelegatedPermissions "Policy.Read.ConditionalAccess|Policy.ReadWrite.ConditionalAccess" `
    

    $requiredResourcesAccess.Add($requiredPermissions)
    Update-MgApplication -ApplicationId $serviceAadApplication.Id -RequiredResourceAccess $requiredResourcesAccess
    Write-Host "Granted permissions."

   # Create the client AAD application
   Write-Host "Creating the AAD application (msal-react-spa-acrs)"
   
   # create the application 
   $clientAadApplication = New-MgApplication -DisplayName "msal-react-spa-acrs" `
                                                      -Spa `
                                                      @{ `
                                                          RedirectUris = "http://localhost:3000"; `
                                                       } `
                                                      -SignInAudience AzureADMyOrg `
                                                      #-PublicClient $False
    $tenantName = (Get-MgApplication -ApplicationId $clientAadApplication.Id).PublisherDomain
    Update-MgApplication -ApplicationId $clientAadApplication.Id -IdentifierUris @("https://$tenantName/msal-react-spa-acrs")
    
    # create the service principal of the newly created application 
    $currentAppId = $clientAadApplication.AppId
    $clientServicePrincipal = New-MgServicePrincipal -AppId $currentAppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}

    # add the user running the script as an app owner if needed
    $owner = Get-MgApplicationOwner -ApplicationId $clientAadApplication.Id
    if ($owner -eq $null)
    { 
        New-MgApplicationOwnerByRef -ApplicationId $clientAadApplication.Id  -BodyParameter = @{"@odata.id" = "htps://graph.microsoft.com/v1.0/directoryObjects/$user.ObjectId"}
        Write-Host "'$($user.UserPrincipalName)' added as an application owner to app '$($clientServicePrincipal.DisplayName)'"
    }
    Write-Host "Done creating the client application (msal-react-spa-acrs)"

    # URL of the AAD application in the Azure portal
    # Future? $clientPortalUrl = "https://portal.azure.com/#@"+$tenantName+"/blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/"+$clientAadApplication.AppId+"/objectId/"+$clientAadApplication.ObjectId+"/isMSAApp/"
    $clientPortalUrl = "https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/CallAnAPI/appId/"+$clientAadApplication.AppId+"/objectId/"+$clientAadApplication.ObjectId+"/isMSAApp/"
    Add-Content -Value "<tr><td>client</td><td>$currentAppId</td><td><a href='$clientPortalUrl'>msal-react-spa-acrs</a></td></tr>" -Path createdApps.html
    $requiredResourcesAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]

    
    # Add Required Resources Access (from 'client' to 'service')
    Write-Host "Getting access from 'client' to 'service'"
    $requiredPermissions = GetRequiredPermissions -applicationDisplayName "msal-node-api-acrs" `
        -requiredDelegatedPermissions "access_as_user" `
    

    $requiredResourcesAccess.Add($requiredPermissions)
    Update-MgApplication -ApplicationId $clientAadApplication.Id -RequiredResourceAccess $requiredResourcesAccess
    Write-Host "Granted permissions."

    # Configure known client applications for service 
    Write-Host "Configure known client applications for the 'service'"
    $knowApplications = New-Object System.Collections.Generic.List[System.String]
    $knowApplications.Add($clientAadApplication.AppId)
    Update-MgApplication -ApplicationId $serviceAadApplication.Id -Api @{KnownClientApplications = $knowApplications}
    Write-Host "Configured."
    
    # Update config file for 'service'
    $configFile = $pwd.Path + "\..\API\.env"
    $dictionary = @{ "Enter_the_Application_Id_Here" = $serviceAadApplication.AppId;"Enter_the_Tenant_Info_Here" = $tenantId;"Enter_the_Client_Secret_Here" = $serviceAppKey };

    Write-Host "Updating the sample code ($configFile)"

    ReplaceInTextFile -configFilePath $configFile -dictionary $dictionary
    
    # Update config file for 'client'
    $configFile = $pwd.Path + "\..\SPA\src\authConfig.js"
    $dictionary = @{ "Enter_the_Application_Id_Here" = $clientAadApplication.AppId;"Enter_the_Tenant_Info_Here" = $tenantId;"Enter_the_Web_Api_Scope_here" = ("api://"+$serviceAadApplication.AppId+"/access_as_user") };

    Write-Host "Updating the sample code ($configFile)"

    ReplaceInTextFile -configFilePath $configFile -dictionary $dictionary
    Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
    Write-Host "IMPORTANT: Please follow the instructions below to complete a few manual step(s) in the Azure portal":
    Write-Host "- For service"
    Write-Host "  - Navigate to $servicePortalUrl"
    Write-Host "  - Navigate to the API Permissions page and select 'Grant admin consent for (your tenant)" -ForegroundColor Red 
    Write-Host "  - Navigate to the Manifest page, find the 'optionalClaims' section and change its default value to request 'xms_cc' claims" -ForegroundColor Red 
    Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
       if($isOpenSSL -eq 'Y')
    {
        Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
        Write-Host "You have generated certificate using OpenSSL so follow below steps: "
        Write-Host "Install the certificate on your system from current folder."
        Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
    }
    Add-Content -Value "</tbody></table></body></html>" -Path createdApps.html  
}

# Run interactively (will ask you for the tenant ID)
ConfigureApplications -tenantId $TenantId