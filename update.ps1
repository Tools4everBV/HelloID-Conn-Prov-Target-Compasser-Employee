#####################################################
# HelloID-Conn-Prov-Target-Compasser-Employee-Update
#
# Version: 1.1.0
#####################################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

$middlenamePartner = $p.Name.familyNamePartnerPrefix
$middlenameBirth = $p.Name.FamilyNamePrefix

if ($p.Name.convention -eq "b") {
    $middlename = $p.Name.FamilyNamePrefix
}
if ($p.Name.convention -eq "bp") {
    $middlename = $p.Name.FamilyNamePrefix
}
if ($p.Name.convention -eq "p") {
    $middlename = $p.Name.familyNamePartnerPrefix
}
if ($p.Name.convention -eq "pb") {
    $middlename = $p.Name.familyNamePartnerPrefix
}

if ($p.Name.convention -eq "b") {
    $lastname = $p.Name.FamilyName
}
if ($p.Name.convention -eq "bp") {
    $lastname = $p.Name.FamilyName + " - " 
    if ($middlenamePartner -eq "") { $lastname = $lastname + " " + $p.Name.familyNamePartner }
    else { $lastname = $lastname + $middlenamePartner + " " + $p.Name.familyNamePartner }
}

if ($p.Name.convention -eq "p") {
    $lastname = $p.Name.familyNamePartner
       
}
if ($p.Name.convention -eq "pb") {
    $lastname = $p.Name.familyNamePartner + " - " 
    if ($middlenameBirth -eq "") { $lastname = $lastname + $p.Name.familyName }
    else { $lastname = $lastname + $middlenameBirth + " " + $p.Name.FamilyName }
}


$gender = switch ($p.Details.gender) {
    { ($_ -eq "man") -or ($_ -eq "male") } { 
        "M"
    }
    { ($_ -eq "vrouw") -or ($_ -eq "female") } {
        "F"
    }
    Default {
        "U"
    }
}

$mappingContractAttribute = { $_.CostCenter.Name }
# mapping between location and project_id
$projectHashTable = @{
    "Administration" = 1001
    "Sales"          = 2001
    "Development"    = 3001
}

# Account mapping
$account = [PSCustomObject]@{
    type                = 'begeleider'
    firstname           = $p.Name.GivenName
    letters             = $p.Name.Initials
    lastname            = $lastname
    linkname            = $middleName
    gender              = $gender
    email               = $p.Accounts.MicrosoftActiveDirectory.mail
    remote_id           = $p.ExternalId
    remindoconnect_code = $p.Accounts.MicrosoftActiveDirectory.userPrincipalName
    project_ids         = "" #Project_id determined automatically later in script
}

#sets null value's to an empty string. This is used for the comparison later in the script
$account.psobject.Properties | ForEach-Object { if ($null -eq $_.value) { $_.value = '' } }

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

#region functions
function Resolve-CompasserError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if ($ErrorObject.ErrorDetails) {
            $errorExceptionDetails = $ErrorObject.ErrorDetails
        }
        elseif ($ErrorObject.Exception.Response) {
            $reader = New-Object System.IO.StreamReader( $ErrorObject.Exception.Response.GetResponseStream())
            $errorExceptionDetails = $reader.ReadToEnd()
            $reader.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($errorExceptionDetails)) {
            $httpErrorObj.ErrorDetails = $errorExceptionDetails
            try {
                $convertedErrorDetails = $httpErrorObj.ErrorDetails | ConvertFrom-Json
                $httpErrorObj.FriendlyMessage = $convertedErrorDetails.error_description
            }
            catch {
                $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
            }
        }
        Write-Output $httpErrorObj
    }
}

function Get-Token {
    [CmdletBinding()]
    param (
        [object]
        $config
    )
    process {
        try {
            $tokenHeaders = [System.Collections.Generic.Dictionary[string, string]]::new()
            $tokenHeaders.Add("Content-Type", "application/x-www-form-urlencoded")

            $body = "client_secret=$($config.clientSecret)&grant_type=client_credentials&client_id=$($config.clientId)"

            $response = Invoke-RestMethod "$($config.baseUrl)/oauth2/token" -Method 'POST' -Headers $tokenHeaders -Body $body -Verbose:$false
            Write-Output $response.access_token
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
        
    }
}
#endregion

# Begin
try {
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Content-Type', 'application/json; charset=utf-8')
    $headers.Add('Accept', 'application/json; charset=utf-8')
    $headers.Add('Authorization', 'Bearer ' + (Get-Token -Config $config))

    Write-Verbose "Verifying if a $($account.firstname) $($account.lastname) account for [$($p.DisplayName)] exists"

    if ($null -eq $aRef) {
        throw 'No account reference is available'
    }
    elseif (-not ($aRef -match '^[0-9]')) {
        throw 'The Account reference does not start with a numeric character, which is not allowed'
    }

    $splatParams = @{
        Uri         = "$($config.BaseUrl)/oauth2/v1/resource/users/$($aRef)"
        Method      = 'GET'
        Headers     = $headers
        ContentType = 'application/json'
    }
    $responseUser = Invoke-RestMethod @splatParams

    [array]$contractsInScope = $p.contracts | Where-Object { $_.Context.InConditions -eq $true }
    if ($null -eq $contractsInScope) {
        throw "Unable to update account for employee [$($account.remote_id)]. No contracts in scope"
    }

    if ((($contractsInScope | Select-Object $mappingContractAttribute).$mappingContractAttribute | Measure-Object).count -ne $contractsInScope.count) {
        Write-Verbose "Not all contracts hold a value with the Contract Property [$mappingContractAttribute]. Verify the Contract Property or your source mapping." -Verbose
        throw  "Not all contracts hold a value with the Contract Property [$mappingContractAttribute]. Verify the Contract Property or your source mapping."
    }

    $locationMapping = ($contractsInScope | Select-Object  $mappingContractAttribute).$mappingContractAttribute
    
    $projects = [System.Collections.Generic.List[System.Object]]::new()
    foreach ($project in $locationMapping) {
        if ($null -eq $projectHashTable[$project]) {
            throw "the contract property [$($mappingContractAttribute)] with value [$($project)] is not found in the projects mapping"
        }
        $projects.Add($projectHashTable[$project])
    }
    $account.project_ids = $projects

    # Verify if the account must be updated
    # Always compare the account against the current account in target system
    $splatCompareProperties = @{
        ReferenceObject  = @($responseUser.users.PSObject.Properties)
        DifferenceObject = @($account.PSObject.Properties)
    }

    $splatCompareProjectIds = @{
        ReferenceObject  = @($responseUser.users.projects.id)
        DifferenceObject = @($account.project_ids)
    }

    $propertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({ $_.SideIndicator -eq '=>' })
    $projectIdsChanged = (Compare-Object @splatCompareProjectIds)

    if (-not $projectIdsChanged) {
        $propertiesChanged = ($propertiesChanged | Where-Object { $_.Name -ne "project_ids" })
    }

    if ($propertiesChanged) {
        $action = 'Update'
        Write-Verbose "Account property(s) required to update: [$($propertiesChanged.name -join ",")]"
        $dryRunMessage = "Account property(s) required to update: [$($propertiesChanged.name -join ",")]"
    }
    else {
        $action = 'NoChanges'
        $dryRunMessage = "No changes will be made to the account during enforcement"
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $dryRunMessage"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Update' {
                Write-Verbose "Updating $($account.firstname) $($account.lastname) account with accountReference: [$aRef]"
                $body = @{}
                foreach ($property in $propertiesChanged) {
                    if ($property.name -eq "project_ids") {
                        $body["$($property.name)"] = @($property.value.id)
                    }
                    else {
                        $body["$($property.name)"] = "$($property.value)"
                    }
                }
                
                $splatParams = @{
                    Uri         = "$($config.BaseUrl)/v1/resource/users/$aref"
                    Method      = 'PUT'
                    Headers     = $headers
                    ContentType = 'application/json'
                    Body        = $body | ConvertTo-Json
                }
                $null = Invoke-RestMethod @splatParams
                break
            }

            'NoChanges' {
                Write-Verbose "No changes to $($account.firstname) $($account.lastname) account with accountReference: [$aRef]"
                break
            }
        }

        $success = $true
        $auditLogs.Add([PSCustomObject]@{
                Message = 'Update account was successful'
                IsError = $false
            })
    }
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CompasserError -ErrorObject $ex
        $auditMessage = "Could not update $($account.firstname) $($account.lastname) account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not update $($account.firstname) $($account.lastname) account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.ScriptLineNumber)': $($ex.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
}
finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Account   = $account
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}