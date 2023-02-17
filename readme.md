
# HelloID-Conn-Prov-Target-Compasser-Employee



| :warning: Warning |
|:---------------------------|
| Note that this connector is "a work in progress" and therefore not ready to use in your production environment. |

| :information_source: Information |
|:---------------------------|
| This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements. |

<p align="center">
  <img src="assets/logo.png">
</p>

## Table of contents

- [Introduction](#Introduction)
- [Getting started](#Getting-started)
  + [Connection settings](#Connection-settings)
  + [Prerequisites](#Prerequisites)
  + [Remarks](#Remarks)
- [Setup the connector](@Setup-The-Connector)
- [Getting help](#Getting-help)
- [HelloID Docs](#HelloID-docs)

## Introduction

_HelloID-Conn-Prov-Target-Compasser-Employee_ is a _target_ connector. Compasser-Employee creates, updates, enables, and disables employee accounts in Compasser. 
An employee account can be associated with one or more locations, which are determined based on the departments obtained from the contracts in scope. 
Further information can be found in the remarks section.

| Endpoint                                          | Description                                   |
| ------------------------------------------------- | --------------------------------------------- |
| /oauth2/token                                     | Gets the Token to connect with the api (POST) |
| /v1/resource/users?filter[remote_id]={remoteId}   | get user based on the remote id (GET)         |
| /v1/resource/users/                               | creates and updates the user (POST), (PUT)    |


The following lifecycle events are available:

| Event       | Description                                 | Notes |
|------------ |---------------------------------------------|------	|
| create.ps1  | Create (or update) and correlate an Account | -     |
| update.ps1  | Update the Account                          | -     |
| enable.ps1  | Enable the Account                          | -     |
| disable.ps1 | Disable the account                         | -     |
| delete.ps1  | No delete script available / Supported      | -     |


## Getting started

### Connection settings

The following settings are required to connect to the API.

| Setting       | Description                             | Mandatory   |
| ------------- | --------------------------------------- | ----------- |
| Client id     | The Client id to connect to the API     | Yes         |
| Client secret | The Client Secret to connect to the API | Yes         |
| BaseUrl       | The URL to the API                      | Yes         |

### Prerequisites
 - Before using this connector, ensure you have the appropriate Client ID and Client Secret in order to connect to the API.
    
#### Creation / correlation process

A new functionality is the possibility to update the account in the target system during the correlation process. By default, this behavior is disabled. Meaning, the account will only be created or correlated.

You can change this behavior in the configuration by selecting the IsUpdatePerson field in the configuration.

> Be aware that this might have unexpected implications.

### Remarks
 - The Remote_Id (EmployeeNumber) is used for correlation, but the Remote_id is not a unique identifier in Compasser. So there might return double entries. Therefore the connector validates if there multiple entries and throws an exception. It would be best if you solved this manually in Compasser.
 - The mapping between location and project_id is defined by a table in the script(s)
 - The current connector gets the location for the location mapping from the contract field $contact.CostCenter.Name. this is done in the create and update script. The location gets mapped to a project id which is then added to employee.

- An example hashtable is used to map the location fetched from the contracts in scope to the project ID. This mapping can also be done using a CSV mapping.  
```powershell
$projectHashTable = @{
    "Administration"  = 1001
    "Sales"           = 2001
    "Development"     = 3001
}
```
- The lookup field utilized to obtain the locations to which an account requires access to. Together with the project hash table to calculate the locations needing to be added to the account.
```powershell
  # Mapping between location and project_id
  $mappingContractAttribute = { $_.CostCenter.Name }
```

## Setup the connector

> _How to setup the connector in HelloID._ Are special settings required. Like the _primary manager_ settings for a source connector.

## Getting help

> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/hc/en-us/articles/360012558020-Configure-a-custom-PowerShell-target-system) pages_

> _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com)_

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
