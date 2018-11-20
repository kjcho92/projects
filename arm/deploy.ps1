<#
 .SYNOPSIS
    Deploys a template to Azure

 .DESCRIPTION
    Deploys an Azure Resource Manager template

 .PARAMETER subscriptionId
    The subscription id where the template will be deployed.

 .PARAMETER resourceGroupName
    The resource group where the template will be deployed. Can be the name of an existing or a new resource group.

 .PARAMETER resourceGroupLocation
    Optional, a resource group location. If specified, will try to create a new resource group in this location. If not specified, assumes resource group is existing.

 .PARAMETER deploymentName
    The deployment name.

 .PARAMETER templateFilePath
    Optional, path to the template file. Defaults to template.json.

 .PARAMETER parametersFilePath
    Optional, path to the parameters file. Defaults to parameters.json. If file is not found, will prompt for parameter values based on template.
#>

param(
# [Parameter(Mandatory=$True)]
 [string]
 # $subscriptionId = "b4beedd6-9009-4be6-88f6-be36ce88cba9", # NovaStaging
 $subscriptionId = "60eceb68-d850-45a2-ad82-86494890fa69", # NovaProd
 
# [Parameter(Mandatory=$True)]
# [string]
# $tenantId,

 #[Parameter(Mandatory=$True)]
 [string]
 $novaSparkPassword = "cAsmoose>104$",

# [Parameter(Mandatory=$True)]
 [string]
 # $resourceGroupName = "armtest",
 $resourceGroupName = "NovaProd",
 
 [string]
 $resourceGroupLocation,

# [Parameter(Mandatory=$True)]
 [string]
 # $productName  = "armtest",
 $productName  = "ProdTest",

# [string]
# $templateFilePath = "template.json", # all
# $templateFilePath = "template-nosfnocert.json"  # All resouces
# $templateFilePath = "sparkOnlytemplate.json", # Spark
# $templateFilePath = "sfOnlytemplate.json", # sf

 $parametersFilePath = "noParam",

 $name = $productName.ToLower(),
 $novaSparkBlobAccountName = "nova$name" + "spark",
 $novaconfigsBlobAccountName = "novaconfigs$name", 

 $NovaServicesKVName = "NovaServicesKV$name",
 $DBName = "nova$name"
)

<#
.SYNOPSIS
    Registers RPs
#>
Function RegisterRP {
    Param(
        [string]$ResourceProviderNamespace
    )

    Write-Host "Registering resource provider '$ResourceProviderNamespace'";
    Register-AzureRmResourceProvider -ProviderNamespace $ResourceProviderNamespace;
}

Function Init([System.String]$templatePath = '') 
{
    $rawData = Get-Content -Raw -Path $templatePath
    $rawData = TranslateTokens -Source $rawData

    Set-Content -Path "temp_$templatePath" -Value $rawData
}


Function TranslateTokens([System.String]$Source = '')
{
   $newStr = $Source.Replace('$name', $name )
   $newStr = $newStr.Replace('$subscriptionId', $subscriptionId )
   
   $newStr = $newStr.Replace('$resourceGroup', $resourceGroupName )
   $newStr = $newStr.Replace('$resourceLocation', "westus2" )
   $newStr = $newStr.Replace('$novaSparkPassword', $novaSparkPassword )   
   $newStr = $newStr.Replace('$tenantId', $tenantId )
   $newStr = $newStr.Replace('$novaSparkBlobAccountName', $novaSparkBlobAccountName )

   # Blob
   $newStr = $newStr.Replace('$eventhubMetricDefaultConnectionString', $eventhubMetricDefaultConnectionString )

   # CosmosDB
   $newStr = $newStr.Replace('$novaopsconnectionString', $novaopsconnectionString )
   $newStr = $newStr.Replace('$novaSparkPassword', $novaSparkPassword ) #deploy.json

   # SF Template
   $newStr = $newStr.Replace('$novaprodsfCertThumbprint', $novaprodsfCert.Thumbprint )
   $newStr = $newStr.Replace('$novaprodsfCertSecretId', $novaprodsfCert.SecretId )
   $newStr = $newStr.Replace('$novaprodsfreverseproxyCertThumbprint', $novaprodsfreverseproxyCert.Thumbprint )
   $newStr = $newStr.Replace('$novaprodsfreverseproxyCertSecretId', $novaprodsfreverseproxyCert.SecretId )

   $newStr
} 

Function GenerateCertsAndImportKeyVault([System.String]$certName = '')
{
    $kvName = "novasfkv$name";
    $subject = "CN=$kvName"+ ".westus2.cloudapp.azure.com";

    $cert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation cert:\LocalMachine\My
 
    # Export the cert to a PFX with password
    $password = ConvertTo-SecureString "abc" -AsPlainText -Force
    $certFileName = "$certName.pfx"

    Export-PfxCertificate -Cert "cert:\LocalMachine\My\$($cert.Thumbprint)" -FilePath $certFileName -Password $password
 
    # Upload to Key Vault

    Import-AzureKeyVaultCertificate -VaultName $kvName -Name $certName -FilePath $certFileName -Password $password

}

Function AddScriptActions()
{
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $novaSparkBlobAccountName;
    $ctx = $storageAccount.Context;

    if ($ctx) {
        $clusterName = "nova" + $name;
        $scriptActionName = "StartMSIServer";
        $scriptActionUri = "https://$novaSparkBlobAccountName.blob.core.windows.net/scripts/novastartmsiserverservice.sh";

        $containerName = "scripts";
        $sourceFileRootDirectory = ".\scripts";
        $nodeTypes = "headnode", "workernode"
    
        try
        {
            New-AzureStorageContainer -Name $containerName -Context $ctx
        }
        catch {}

        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) 
        {
            $rawData = Get-Content -Raw -Path $x.fullname
            $rawData = TranslateTokens -Source $rawData
            Set-Content -Path $x.name -Value $rawData

            Write-Verbose "Uploading $("\" + $x.name.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            Set-AzureStorageBlobContent -File $x.name -Container $containerName -Context $ctx -Force:$Force | Out-Null
        }
    
        try {        
        Submit-AzureRmHDInsightScriptAction -ClusterName $clusterName `
            -Name $scriptActionName `
            -Uri $scriptActionUri `
            -NodeTypes $nodeTypes `
            -PersistOnSuccess
        }
        catch {}
    }
}

Function SetupCosmosDB()
{
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $novaconfigsBlobAccountName

  
    Connect-Mdbc -ConnectionString $dbCon -DatabaseName "production"
    $colnames = @(
        "azureStorages",
        "commons",
        "metricSources",
        "metricWidgets",
        "novaFlowConfigs",
        "products",
        "sparkClusters",
        "sparkJobs",
        "sparkJobTemplates"
    )

    $colnames | foreach {
        try{
             $response = Add-MdbcCollection -Name $_
                if (!$response) {
                throw
            }
        }
        catch
        {}
    }
    
    $templatePath = ".\CosmosDB"; #path to templates
    $qry = New-MdbcQuery -Name "_id" -Exists
    $colnames | foreach{
        $colName = $_
        $collection1 = $Database.GetCollection($colName)

        Remove-MdbcData -Query $qry -Collection $collection1

    #    $json = Get-Content -Raw -Path "$templatePath\$colName.json" | ConvertFrom-Json 
        $rawData = Get-Content -Raw -Path "$templatePath\$colName.json"
        $rawData = TranslateTokens -Source $rawData
        $json = ConvertFrom-Json -InputObject $rawData


        $json | foreach {
            try
            {
                $_ | ConvertTo-Json | Set-Content t.json
                $input = Import-MdbcData t.json
                $response = Add-MdbcData -InputObject $input -Collection $collection1 -NewId
                if (!$response) {
                    throw
                }
            }
            catch{}
        }
    }

    Remove-Module Mdbc  
}

Function SetupBlob()
{
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $novaconfigsBlobAccountName;
    $ctx = $storageAccount.Context;
    
    if ($ctx)
    {
        $containerName = "referencedata";
        $sourceFileRootDirectory = ".\Blob\$containerName"
        $scriptRoot = $PSScriptRoot + "\Blob\$containerName";

        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) {
            $targetPath = ($x.fullname.Substring($scriptRoot.Length + 1)).Replace("\", "/")
    #        $targetPath = ($x.fullname.Substring($sourceFileRootDirectory.Length + 1)).Replace("\", "/")
    #        $targetPath = $sourceFileRootDirectory.Replace("\", "/")

            Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            Set-AzureStorageBlobContent -File $x.fullname -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        }

        $containerName = "rules";
        $sourceFileRootDirectory = ".\Blob\$containerName"
        $scriptRoot = $PSScriptRoot + "\Blob\$containerName";

        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) {        
            $targetPath = ($x.fullname.Substring($scriptRoot.Length + 1)).Replace("\", "/")
    #        $targetPath = ($x.fullname.Substring($sourceFileRootDirectory.Length + 1)).Replace("\", "/")
    #        $targetPath = $sourceFileRootDirectory.Replace("\", "/")

            Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            Set-AzureStorageBlobContent -File $x.fullname -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        }

        $containerName = "centralprocessing";
        $sourceFileRootDirectory = ".\Blob\$containerName"
        $scriptRoot = $PSScriptRoot + "\Blob\$containerName";

        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) {
            $targetPath = ($x.fullname.Substring($scriptRoot.Length + 1)).Replace("\", "/")
    #        $targetPath = ($x.fullname.Substring($sourceFileRootDirectory.Length + 1)).Replace("\", "/")
    #        $targetPath = $sourceFileRootDirectory.Replace("\", "/")

            $rawData = Get-Content -Raw -Path $x.fullname
            TranslateTokens -Source $rawData | Set-Content t.json

            Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            Set-AzureStorageBlobContent -File t.json -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        }
    }
}

Function SetupSecrets()
{
    $Secret = ConvertTo-SecureString -String $dbCon -AsPlainText -Force

    $t = "novaconfigs$name" + "ConnectionString";
    Set-AzureKeyVaultSecret -VaultName "$NovaServicesKVName" -Name $t -SecretValue $Secret
        
    $t = "nova$name" + "Password";    
    $Secret = ConvertTo-SecureString -String $novaSparkPassword -AsPlainText -Force
    Set-AzureKeyVaultSecret -VaultName "$NovaServicesKVName" -Name $t -SecretValue $Secret

    $Secret = ConvertTo-SecureString -String $dbCon -AsPlainText -Force 
    Set-AzureKeyVaultSecret -VaultName "$NovaServicesKVName" -Name "novaconfiggen-novaflowconfigs" -SecretValue $Secret

    $t = "novaconfigs$name" + "-blobconnectionstring";    
    $Secret = ConvertTo-SecureString -String $novaopsconnectionString -AsPlainText -Force
    Set-AzureKeyVaultSecret -VaultName "$NovaServicesKVName" -Name $t -SecretValue $Secret

}

#******************************************************************************
# Script body
# Execution begins here
#******************************************************************************
$ErrorActionPreference = "Stop"

$dbConRaw = Invoke-AzureRmResourceAction -Action listConnectionStrings `
    -ResourceType "Microsoft.DocumentDb/databaseAccounts" `
    -ApiVersion "2015-04-08" `
    -ResourceGroupName $resourceGroupName `
    -Name $DBName `
    -force

$dbCon = $dbConRaw.connectionStrings[0].connectionString

$novaopsconnectionString = ''
if ($storageAccount.Context.ConnectionString -match '(AccountName=.*)')
{
    $connectionString = $Matches[0]
    $novaopsconnectionString = "DefaultEndpointsProtocol=https;$connectionString;EndpointSuffix=core.windows.net"
}
    

# sign in
Write-Host "Logging in...";
#$acc = Login-AzureRmAccount;
#$acc = Connect-AzureRmAccount;
#$tenantId = $acc.Context.Tenant.Id
$tenantId = "72f988bf-86f1-41af-91ab-2d7cd011db47";

# select subscription
Write-Host "Selecting subscription '$subscriptionId'";
Select-AzureRmSubscription -SubscriptionID $subscriptionId;

# Register RPs
$resourceProviders = @("microsoft.cache","microsoft.compute","microsoft.documentdb","microsoft.eventhub","microsoft.insights","microsoft.keyvault","microsoft.network","microsoft.servicefabric","microsoft.storage","microsoft.web");
if($resourceProviders.length) {
    Write-Host "Registering resource providers"
    foreach($resourceProvider in $resourceProviders) {
        # RegisterRP($resourceProvider);
    }
}

#Create or check for existing resource group
$resourceGroup = Get-AzureRmResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if(!$resourceGroup)
{
    Write-Host "Resource group '$resourceGroupName' does not exist. To create a new resource group, please enter a location.";
    if(!$resourceGroupLocation) {
        $resourceGroupLocation = Read-Host "resourceGroupLocation";
    }
    Write-Host "Creating resource group '$resourceGroupName' in location '$resourceGroupLocation'";
    New-AzureRmResourceGroup -Name $resourceGroupName -Location $resourceGroupLocation
}
else{
    Write-Host "Using existing resource group '$resourceGroupName'";
}

# Start the deployment
Write-Host "Starting deployment...";

$templateFilePath = "template.json"
# Initialize
Init -templatePath $templateFilePath

if(Test-Path "temp_$templateFilePath") {
#    New-AzureRmResourceGroupDeployment -Debug -ResourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePath";
}
# $novaprodsfCert = GenerateCertsAndImportKeyVault -certName "novaprodsf"
# $novaprodsfreverseproxyCert = GenerateCertsAndImportKeyVault -certName "novaprodsfreverseproxy"


# Start SF deployment
Write-Host "Starting SF deployment...";
$templateFilePathForSF = "sf-template.json"
#$templateFilePathForSF = "sfonly-template.json"
Init -templatePath $templateFilePathForSF
if(Test-Path "temp_$templateFilePathForSF")
{
    New-AzureRmResourceGroupDeployment -Debug -ResourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePathForSF";
}

# Spark
AddScriptActions

# Blob
SetupBlob

# cosmosDB
SetupCosmosDB

# Secrets
SetupSecrets