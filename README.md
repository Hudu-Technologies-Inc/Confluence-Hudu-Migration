# Confluence-Hudu-Migration

Easily transfer your Confluence pages over to Hudu!

# Getting Started

## Prerequisites

Ensure you have:

- Hudu instance ready to go with your API key on-hand
- Confluence instance ready to transfer with API key on-hand
- Powershell 7.5.0 or later is reccomended for running this script

## Starting

It's reccomended to instantiate via dot-sourcingl, ie

```
. .\Confluence-Migration.ps1
```

It will load HuduAPI powershell module
- locally if present in this folder: "C:\Users\$env:USERNAME\Documents\GitHub\HuduAPI\HuduAPI\HuduAPI.psm1"
- otherwise from Powershell Gallery

