#####################################################
# HelloID-Conn-Prov-Target-Compasser-Employee-Create
#
# Version: 1.0.0
#####################################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

switch ($p.Details.gender) {
    { ($_ -eq "man") -or ($_ -eq "male") } {
        $gender = "M"
    }
    { ($_ -eq "vrouw") -or ($_ -eq "female") } {
        $gender = "F"
    }
    Default {
        $gender = "U"
    }
}

# mapping between location and project_id
$mappingContractAttribute = { $_.CostCenter.Name }
$projectHashTable = @{
    "Administration"  = 1001
    "Sales"           = 2001
    "Development"     = 3001
}

# Account mapping
$account = [PSCustomObject]@{
    type        = 'begeleider'
    firstname   = $p.Name.GivenName
    letters     = $p.Name.Initials
    lastname    = $p.Name.FamilyName
    gender      = $gender
    email       = $p.Accounts.MicrosoftActiveDirectory.mail
    remote_id   = $p.ExternalId
    project_ids = "" #Project_id determined automatically later in script
}

#sets null value's to an empty string
$account.psobject.Properties | ForEach-Object { if ($null -eq $_.value) { $_.value = '' } }

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

# Set to true if accounts in the target system must be updated
$updatePerson = $false

#region functions
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
            ErrorDetails     = ''
            FriendlyMessage  = ''
        }
        if ($ErrorObject.ErrorDetails) {
            $errorExceptionDetails = $ErrorObject.ErrorDetails
        } elseif ($ErrorObject.Exception.Response) {
            $reader = New-Object System.IO.StreamReader( $ErrorObject.Exception.Response.GetResponseStream())
            $errorExceptionDetails = $reader.ReadToEnd()
            $reader.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($errorExceptionDetails)) {
            $httpErrorObj.ErrorDetails = $errorExceptionDetails
            try {
                $convertedErrorDetails = $httpErrorObj.ErrorDetails | ConvertFrom-Json
                $httpErrorObj.FriendlyMessage = $convertedErrorDetails.error_description
            } catch {
                $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
            }
        } else {
            $httpErrorObj.ErrorDetails = $ErrorObject.Exception.Message
            $httpErrorObj.FriendlyMessage = $ErrorObject.Exception.Message
        }
        Write-Output $httpErrorObj
    }
}
#endregion

# Begin
try {
    $accessToken = Get-Token -Config $config

    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Content-Type', 'application/json; charset=utf-8')
    $headers.Add('response-Type', 'application/json; charset=utf-8')
    $headers.Add('Authorization', 'Bearer ' + $accessToken)

    [array]$contractsInScope = $p.contracts | Where-Object { $_.Context.InConditions -eq $true }
    if ($null -eq $contractsInScope) {
        throw "Unable to create account for employee [$($account.remote_id)]. No contracts in scope"
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

    $splatParams = @{
        Uri         = "$($config.BaseUrl)/v1/resource/users?filter[remote_id]=$($account.remote_id)"
        Method      = 'GET'
        Headers     = $headers
        ContentType = 'application/json'
    }
    $responseUser = Invoke-RestMethod @splatParams
        
    # Verify if a user must be either [created and correlated], [updated and correlated] or just [correlated]
    if ($responseUser.users.Count -gt 1) {
        $success = $false
        throw "multiple persons with remote_id [$($account.remote_id)] found."
    }

    if ($responseUser.users.Count -eq 0) {
        $responseUser = $null
        $action = 'Create-Correlate'
    }
    elseif ($updatePerson -eq $true) {
        $action = 'Update-Correlate'
    }
    else {
        $action = 'Correlate'
    }

    # Add a warning message showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $action Compasser-Employee account for: [$($p.DisplayName)], will be executed during enforcement"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Create-Correlate' {
                Write-Verbose "Creating and correlating Compasser-Employee account"

                $splatParams = @{
                    Uri         = "$($config.BaseUrl)/v1/resource/users"
                    Method      = 'POST'
                    Headers     = $headers
                    Body        = $account | ConvertTo-Json
                    ContentType = 'application/json'
                }
                $responseCreateUser = Invoke-RestMethod @splatParams

                #result is an url with at the end the user id, replacing everything before the last slash with nothing results in only the user id.
                $accountReference = $responseCreateUser.location -replace '.*/'
                break
            }

            'Update-Correlate' {
                Write-Verbose "Updating and correlating Compasser-Employee account"
                $splatParams = @{
                    Uri         = "$($config.BaseUrl)/v1/resource/users/$($responseUser.users.id)"
                    Method      = 'PUT'
                    Headers     = $headers
                    Body        = $account | ConvertTo-Json
                    ContentType = 'application/json'
                }
                $responseUpdateUser = Invoke-RestMethod @splatParams
                $accountReference = $responseUpdateUser.users.id

                break
            }

            'Correlate' {
                Write-Verbose "Correlating Compasser-Employee account"
                $accountReference = $responseUser.users.id
                break
            }
        }

        $success = $true
        $auditLogs.Add([PSCustomObject]@{
                Message = "$action account for Project(s) [$($account.project_ids -join ', ')] was successful. AccountReference is: [$accountReference]"
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
            $auditMessage = "Could not $action Compasser-Employee account. Error: $($errorObj.FriendlyMessage)"
            Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        }
        else {
            $auditMessage = "Could not $action Compasser-Employee account. Error: $($errorObj.FriendlyMessage)"
            Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        }
    Write-Verbose $auditMessage
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
# End
finally {
    $result = [PSCustomObject]@{
        Success          = $success
        AccountReference = $accountReference
        Auditlogs        = $auditLogs
        Account          = $account
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
