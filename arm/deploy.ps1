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

 [string]
# $templateFilePath = "template-nosfnocert.json"  # All resouces
 $templateFilePath = "sparkOnlytemplate.json", # Spark

 $parametersFilePath = "noParam",
 
)

Function Init {
    $novaSparkBlobAccountName = "nova" + $productName.ToLower() + "spark";

    $rawData = Get-Content -Raw -Path "$templateFilePath"
    $rawData = TranslateTokens -Source $rawData

    Set-Content -Path temp.json -Value $rawData
}

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

Function TranslateTokens([System.String]$Source = '')
{
   $newStr = $Source.Replace('$name', $productName.ToLower() )
   $newStr = $newStr.Replace('$subscriptionId', $subscriptionId )
   $newStr = $newStr.Replace('$resourceGroup', $resourceGroupName )
   $newStr = $newStr.Replace('$novaSparkPassword', $novaSparkPassword )   
   $newStr = $newStr.Replace('$tenantId', $tenantId )
   $newStr = $newStr.Replace('$novaSparkBlobAccountName', $novaSparkBlobAccountName )

   // Blob
   $newStr = $newStr.Replace('$novaopsconnectionString', $novaopsconnectionString )
   $newStr = $Source.Replace('$eventhubMetricDefaultConnectionString', $eventhubMetricDefaultConnectionString )
   $newStr
} 

Function AddScriptActions()
{
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $novaSparkBlobAccountName;
    $ctx = $storageAccount.Context;

    if ($ctx) {
        $clusterName = "nova" + $productName.ToLower();
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
    
        Submit-AzureRmHDInsightScriptAction -ClusterName $clusterName `
            -Name $scriptActionName `
            -Uri $scriptActionUri `
            -NodeTypes $nodeTypes `
            -PersistOnSuccess
    }
}

Function SetupBlob()
{
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $novaOpsDBName;
    $ctx = $storageAccount.Context;

    $novaopsconnectionString = ''
    if ($storageAccount.Context.ConnectionString -match '(AccountName=.*)')
    {
        $connectionString = $Matches[0]
        $novaopsconnectionString = "DefaultEndpointsProtocol=https;$connectionString;EndpointSuffix=core.windows.net"
    }

    
    if ($ctx)
    {
        $containerName = "referencedata";
        $sourceFileRootDirectory = ".\Blob\$containerName"

        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) {
            $targetPath = ($x.fullname.Substring($sourceFileRootDirectory.Length + 1)).Replace("\", "/")
    #        $targetPath = $sourceFileRootDirectory.Replace("\", "/")

            Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            Set-AzureStorageBlobContent -File $x.fullname -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        }

        $containerName = "rules";
        $sourceFileRootDirectory = ".\Blob\$containerName"

        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) {
            $targetPath = ($x.fullname.Substring($sourceFileRootDirectory.Length + 1)).Replace("\", "/")
    #        $targetPath = $sourceFileRootDirectory.Replace("\", "/")

            Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            Set-AzureStorageBlobContent -File $x.fullname -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        }

        $containerName = "centralprocessing";
        $sourceFileRootDirectory = ".\Blob\$containerName"

        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) {
            $targetPath = ($x.fullname.Substring($sourceFileRootDirectory.Length + 1)).Replace("\", "/")
    #        $targetPath = $sourceFileRootDirectory.Replace("\", "/")

            $rawData = Get-Content -Raw -Path $x.fullname
            TranslateTokens -Source $rawData | Set-Content t.json

            Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            Set-AzureStorageBlobContent -File t.json -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        }
    }

}

#******************************************************************************
# Script body
# Execution begins here
#******************************************************************************
$ErrorActionPreference = "Stop"

# Initialize
Init
    
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
if(Test-Path $parametersFilePath) {
#    New-AzureRmResourceGroupDeployment -Debug -ResourceGroupName $resourceGroupName -TemplateFile temp.json;
} else {
#    New-AzureRmResourceGroupDeployment -Debug -ResourceGroupName $resourceGroupName -TemplateFile temp.json -TemplateParameterFile $parametersFilePath;
}

# Spark
AddScriptActions

# Blob
SetupBlob