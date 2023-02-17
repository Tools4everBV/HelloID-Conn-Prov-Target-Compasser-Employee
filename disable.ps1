#####################################################
# HelloID-Conn-Prov-Target-Compasser-Employee-Disable
#
# Version: 1.0.0
#####################################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

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
            ErrorDetails     = ''
            FriendlyMessage  = ''
        }
        if ($ErrorObject.ErrorDetails) {
            $errorExceptionDetails = $ErrorObject.ErrorDetails
        } elseif ($ErrorObject.Exception.Response) {
            $reader = [System.IO.StreamReader]::new( $ErrorObject.Exception.Response.GetResponseStream())
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
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}
#endregion

# Begin
try {
    Write-Verbose "Verifying if a Compasser-Employee account for [$($p.DisplayName)] exists"

    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Content-Type', 'application/json; charset=utf-8')
    $headers.Add('response-Type', 'application/json; charset=utf-8')
    $headers.Add('Authorization', 'Bearer ' + (Get-Token -Config $config))

    if ($null -eq $aRef) {
        throw 'No account reference is available'
    }

    $splatParams = @{
        Uri     = "$($config.BaseUrl)/v1/resource/users/$aref"
        Method  = 'Get'
        Headers = $headers
    }
    try {
        $null = Invoke-RestMethod @splatParams  -Verbose:$false
        $action = 'Found'
        $dryRunMessage = "Disable Compasser-Employee account for: [$($p.DisplayName)] will be executed during enforcement"
    } catch {
        $errorObj = Resolve-CompasserError -ErrorObject $_
        if ($errorObj.FriendlyMessage -match 'not found') {
            $action = 'NotFound'
            $dryRunMessage = "Compasser-Employee account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
        } else {
            throw $_
        }
    }
    Write-Verbose $dryRunMessage


    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $dryRunMessage"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Found' {
                Write-Verbose "Disable Compasser-Employee account with accountReference: [$aRef]"
                $splatParams = @{
                    Uri         = "$($config.BaseUrl)/v1/resource/users/$aref"
                    Method      = 'PUT'
                    Headers     = $headers
                    ContentType = 'application/json'
                    Body        = '{"status": "inactive"}'
                }
                $null = Invoke-RestMethod @splatParams  -Verbose:$false

                $auditLogs.Add([PSCustomObject]@{
                        Message = 'Disable account was successful'
                        IsError = $false
                    })
                break
            }

            'NotFound' {
                $auditLogs.Add([PSCustomObject]@{
                        Message = "Compasser-Employee account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
                        IsError = $false
                    })
                break
            }
        }

        $success = $true
    }
} catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CompasserError -ErrorObject $ex
        $auditMessage = "Could not disable Compasser-Employee account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not disable Compasser-Employee account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
} finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
