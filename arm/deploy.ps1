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
# [string]
 $subscriptionId = "60eceb68-d850-45a2-ad82-86494890fa69",
 
# [Parameter(Mandatory=$True)]
# [string]
 $novaSparkPassword = "cAsmoose>104$",

# [Parameter(Mandatory=$True)]
# [string]
 $resourceGroupName = "NovaProd",
 
# [Parameter(Mandatory=$True, HelpMessage="Location for Microsoft.Insights")]
# [ValidateSet("EastUS", "SouthCentralUS", "NorthEurope", "WestEurope", "SoutheastAsia", "WestUS2", "CanadaCentral", "CentralIndia")]
# [string]
 $resourceLocationForMicrosoftInsights = "westus2",
 
# [Parameter(Mandatory=$True, HelpMessage="Location for Microsoft.ServiceFabric")]
# [string]
 $resourceLocationForServiceFabric = "westus2",
 
 [string]
 $resourceGroupLocation,

# [Parameter(Mandatory=$True)]
# [string]
# $productName,
 $productName  = "prod",

 $parametersFilePath = "noParam",

 # Resources Names
 $name = $productName.ToLower(),
 $novaSparkBlobAccountName = "nova$name" + "spark",
 $novaconfigsBlobAccountName = "novaconfigs$name", 

 $NovaServicesKVName = "NovaServicesKV$name",
 $NovaSparkKVName = "NovaSparkKV$name",
 $NovaSparkRDPKVName = "NovaSparkRDPKV$name",
 $NovaFabricRDPKVName = "NovaFabricRDPKV$name",

#  $CertsPath = "",
 $CertsPath = ".\Certs",

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
   $newStr = $newStr.Replace('$resourceLocationForMicrosoftInsights', $resourceLocationForMicrosoftInsights )

   $newStr = $newStr.Replace('$novaSparkPassword', $novaSparkPassword )
   $newStr = $newStr.Replace('$tenantId', $tenantId )
   $newStr = $newStr.Replace('$userId', $userId )
   $newStr = $newStr.Replace('$novaSparkBlobAccountName', $novaSparkBlobAccountName )

   # Blob
   $newStr = $newStr.Replace('$eventhubMetricDefaultConnectionString', $eventhubMetricDefaultConnectionString )

   # CosmosDB
   $newStr = $newStr.Replace('$novaopsconnectionString', $novaopsconnectionString )
   $newStr = $newStr.Replace('$novaSparkPassword', $novaSparkPassword )
   $newStr = $newStr.Replace('$configgenClientId', $azureADApplicationConfiggen.ApplicationId )
   $newStr = $newStr.Replace('$configgenTenantId', $tenantId )
   try
   {
    $newStr = $newStr.Replace('$appinsightkey', (Get-AzureRmApplicationInsights -ResourceGroupName $ResourceGroupName -Name nova$name).InstrumentationKey )
   }
   catch {}

   # SF Template
   $newStr = $newStr.Replace('$novaprodsfCertThumbprint', $novaprodsfCert.Certificate.Thumbprint )
   $newStr = $newStr.Replace('$novaprodsfCertSecretId', $novaprodsfCert.SecretId )
   $newStr = $newStr.Replace('$novaprodsfreverseproxyCertThumbprint', $novaprodsfreverseproxyCert.Certificate.Thumbprint )
   $newStr = $newStr.Replace('$novaprodsfreverseproxyCertSecretId', $novaprodsfreverseproxyCert.SecretId )
   $newStr = $newStr.Replace('$resourceLocationForServiceFabric', $resourceLocationForServiceFabric )
   
   $newStr = $newStr.Replace('$resourceLocation', $resourceGroupLocation )

   $newStr
} 

Function SetAzureADAppSecret([System.String]$AppName = '')
{
    $app = Get-AzureRmADApplication -DisplayNameStartWith $AppName
    if ($app)
    {
        $startDate = Get-Date
        $endDate = $startDate.AddYears(2)

        $keyValue = New-AzureADApplicationPasswordCredential -ObjectId $app.ObjectId -StartDate $startDate -EndDate $endDate
    }

    # $keyValue = Get-AzureADApplicationPasswordCredential -ObjectId $azureADApplication.ObjectId

    # if ($keyValue)
    # {
    #     $startDate = Get-Date
    #     $endDate = $startDate.AddYears(2)
    #     $keyValue = New-AzureADApplicationPasswordCredential -ObjectId $azureADApplication.ObjectId -StartDate $startDate -EndDate $endDate
    # }

    $keyValue
}

Function GenerateAzureADApplication([System.String]$novaAppName = '', [System.String]$websiteName = '')
{
    # New-AzureADApplication -DisplayName "nova$name"  -IdentifierUris "https://nova$name.azurewebsites.net" -ReplyUrls "https://nova$name.azurewebsites.net/authReturn"
    $app = Get-AzureRmADApplication -DisplayNameStartWith $novaAppName
    if (!$app)
    {
        if ($websiteName){
            $app = New-AzureRmADApplication  -DisplayName $novaAppName -IdentifierUris "https://$tenantName/$novaAppName" -ReplyUrls "https://$websiteName.azurewebsites.net/authReturn"
        }
        else {
            $app = New-AzureRmADApplication  -DisplayName $novaAppName -IdentifierUris "https://$tenantName/$novaAppName" 
            
            $cer = $novaprodsfCert.Certificate
            $certValue = [System.Convert]::ToBase64String($cer.GetRawCertData())
    
            New-AzureRmADAppCredential -ApplicationId $app.ApplicationId -CertValue $certValue -StartDate $cer.NotBefore -EndDate $cer.NotAfter
        }
    }

    $servicePrincipal = Get-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId
    if (!$servicePrincipal)
    {
         $servicePrincipal = New-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId
    }

    $app
}

Function GenerateCertsAndImportKeyVault([System.String]$certName = '')
{
    $kvName = "novasfKV$name";
    $subject = "CN=$kvName"+ ".$resourceLocationForServiceFabric" + ".cloudapp.azure.com";
    
    $cert
    if (!$CertsPath)
    {
        $cert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation cert:\LocalMachine\My
    }
    else {
        $path = $CertsPath + "\$certName.cer"
        $cert = Import-Certificate -CertStoreLocation cert:\LocalMachine\My -FilePath $path
    }
     
    # Export the cert to a PFX with password
    $password = ConvertTo-SecureString "password" -AsPlainText -Force
    $certFileName = "$certName.pfx"

    Export-PfxCertificate -Cert "cert:\LocalMachine\My\$($cert.Thumbprint)" -FilePath $certFileName -Password $password

    # Upload to Key Vault
    Import-AzureKeyVaultCertificate -VaultName $kvName -Name $certName -FilePath $certFileName -Password $password
    $cert
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
            #New-AzureStorageContainer -Name "deployment" -Context $ctx
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
    # $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $novaconfigsBlobAccountName

  
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


Function SetupBlobHelper([System.String]$containerName = '', [System.String]$saname = '')
{
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $saname;
    $ctx = $storageAccount.Context;

    if ($ctx)
    {
        $sourceFileRootDirectory = ".\Blob\$containerName"
        $scriptRoot = $PSScriptRoot + "\Blob\$containerName";
        
        try
        {
            New-AzureStorageContainer -Name $containerName -Context $ctx
            #New-AzureStorageContainer -Name "deployment" -Context $ctx
        }
        catch {}

        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) {
            $targetPath = ($x.fullname.Substring($scriptRoot.Length + 1)).Replace("\", "/")

            Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            Set-AzureStorageBlobContent -File $x.fullname -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        }
    }   
}

Function SetupBlob()
{
    
        SetupBlobHelper -containerName  "deployment" -saname $novaconfigsBlobAccountName
        SetupBlobHelper -containerName  "rules" -saname $novaconfigsBlobAccountName
        SetupBlobHelper -containerName  "centralprocessing"  -saname $novaconfigsBlobAccountName
        SetupBlobHelper -containerName  "deployment" -saname $novaSparkBlobAccountName

        # $containerName = "deployment";
        # $sourceFileRootDirectory = ".\Blob\$containerName"
        # $scriptRoot = $PSScriptRoot + "\Blob\$containerName";

        # $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        # foreach ($x in $filesToUpload) {
        #     $targetPath = ($x.fullname.Substring($scriptRoot.Length + 1)).Replace("\", "/")

        #     Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
        #     Set-AzureStorageBlobContent -File $x.fullname -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        # }

        # $containerName = "rules";
        # $sourceFileRootDirectory = ".\Blob\$containerName"
        # $scriptRoot = $PSScriptRoot + "\Blob\$containerName";

        # $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        # foreach ($x in $filesToUpload) {        
        #     $targetPath = ($x.fullname.Substring($scriptRoot.Length + 1)).Replace("\", "/")

        #     Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
        #     Set-AzureStorageBlobContent -File $x.fullname -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        # }

        # $containerName = "centralprocessing";
        # $sourceFileRootDirectory = ".\Blob\$containerName"
        # $scriptRoot = $PSScriptRoot + "\Blob\$containerName";

        # $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        # foreach ($x in $filesToUpload) {
        #     $targetPath = ($x.fullname.Substring($scriptRoot.Length + 1)).Replace("\", "/")

        #     $rawData = Get-Content -Raw -Path $x.fullname
        #     TranslateTokens -Source $rawData | Set-Content t.json

        #     Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
        #     Set-AzureStorageBlobContent -File t.json -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        # }
    # }

    # $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $novaSparkBlobAccountName;
    # $ctx = $storageAccount.Context;

    # if ($ctx) {
        
        # $containerName = "deployment";
        # $sourceFileRootDirectory = ".\Blob\$containerName"
        # $scriptRoot = $PSScriptRoot + "\Blob\$containerName";

        # $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        # foreach ($x in $filesToUpload) {
        #     $targetPath = ($x.fullname.Substring($scriptRoot.Length + 1)).Replace("\", "/")

        #     Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
        #     Set-AzureStorageBlobContent -File $x.fullname -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
        # }
    # }
}

Function SetupSecretHelper([System.String]$VaultName = '', [System.String]$SecretName = '', [System.String]$Value = '')
{    
    $secret = ConvertTo-SecureString -String $Value -AsPlainText -Force
    Set-AzureKeyVaultSecret -VaultName $VaultName -Name $SecretName -SecretValue $secret
}

Function InvokeAzureRmResourceAction([System.String]$Actions = '', [System.String]$ResourceType = '', [System.String]$ApiVersion = '', [System.String]$ResourceName = '')
{    
    $ret = Invoke-AzureRmResourceAction -Action $Actions `
    -ResourceType $ResourceType `
    -ApiVersion $ApiVersion `
    -ResourceGroupName $resourceGroupName `
    -Name $ResourceName `
    -force

    $ret
}

Function SetupSecrets()
{
    #NovaServicesKVName

    $vaultName = "$NovaServicesKVName"
    $prefix = "novaconfiggen-";

    $secretName = "novaconfigs$name" + "ConnectionString" # Needed?
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaopsconnectionString

    $secretName = $prefix + "novaflowconfigs";
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $dbCon

    $secretName = $prefix + "novaflowconfigsdatabasename"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "production"

    $secretName = $prefix + "nova$name" + "password"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaSparkPassword

    $secretName = $prefix + "novaconfigs$name" + "-blobconnectionstring"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaopsconnectionString

    $secretName = $prefix + "aiInstrumentationKey"    
    $aiKey = (Get-AzureRmApplicationInsights -ResourceGroupName $ResourceGroupName -Name nova$name).InstrumentationKey
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $aiKey

    $secretName = $prefix + "clientsecret"    
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $azureADAppSecretConfiggen.Value

    $secretName = $prefix + "azureservicesauthconnectionstring"    
    $tValue = "<EnvironmentVariable Name=""AzureServicesAuthConnectionString"" Value=""RunAs=App;AppId=" + $azureADApplicationConfiggen.ApplicationId + ";TenantId=" + $tenantId + ";CertificateThumbprint=" + $novaprodsfCert.Certificate.Thumbprint + ";CertificateStoreLocation=LocalMachine""/>"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue

    $prefix = "novaweb-dev-";
    $secretName = $prefix + "aiKey"    
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $aiKey
    

    $secretName = $prefix + "clientId"    
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $azureADApplication.ApplicationId

    $secretName = $prefix + "clientSecret"    
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $azureADAppSecret.Value

    $secretName = $prefix + "datahubClusterUrl"    
    $sfName = "novasf-$name"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "https://$sfName"+ ".$resourceLocationForServiceFabric" + ".cloudapp.azure.com"

    $secretName = $prefix + "datahubResourceId"
    $novaAppName = "novaapp$name"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "https://$tenantName/$novaAppName"

    $secretName = $prefix + "mongoDbUrl"    
    $tValue = $dbCon.Replace("/?ssl=true", "/production?ssl=true")
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue

    $secretName = $prefix + "redisDataConnectionString" 
    $redisKey = (Get-AzureRmRedisCacheKey -Name nova$name -ResourceGroupName $ResourceGroupName).PrimaryKey
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "nova$name.redis.cache.windows.net:6380,password=$redisKey,ssl=True,abortConnect=False"
    
    $secretName = $prefix + "sessionSecret"       
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "test"

    $secretName = $prefix + "subscriptionId"       
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $subscriptionId

    $secretName = $prefix + "tenantName"    
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tenantName

    #NovaServicesKVName

    $vaultName = "$NovaSparkKVName"
    $prefix = "";
    
    $secretName = $prefix + "nova-sa-" + $novaconfigsBlobAccountName    
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $novaconfigsBlobAccountName;
    $tValue = ""
    if ($storageAccount.Context.ConnectionString -match 'AccountKey=(.*)')
    {
        $tValue = $Matches[1].Replace("AccountKey=", "")
    }

    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue
    
    $secretName = $prefix + "metric-eventhubconnectionstring"    
    $tValue = (Get-AzureRmEventHubKey -ResourceGroupName $resourceGroupName -NamespaceName novametricseventhub$name -EventHubName novametricseventhub -AuthorizationRuleName manage).PrimaryConnectionString
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue
    
    $secretName = $prefix + "metric-eventhubdefaultconnectionstring"    
    $tValue = (Get-AzureRmEventHubKey -ResourceGroupName $resourceGroupName -NamespaceName novametricseventhub$name -EventHubName novametricseventhubdefault -AuthorizationRuleName manage).PrimaryConnectionString
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue
       
    # NovaSparkRDPKVName
    $vaultName = "NovaSparkRDPKV$name"
    $prefix = "";
    
    $secretName = $prefix + "sshuser" 
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaSparkPassword
        
    # NovaFabricRDPKVName
    $vaultName = "$NovaFabricRDPKVName"
    $prefix = "";
    
    $secretName = $prefix + "novasfadminpassword" 
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaSparkPassword
    
    $secretName = $prefix + "novasfadminuser" 
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "novapd"    
}


Function SetupKVAccess()
{
    $novaAppName = "novaapp$name"
    $app = Get-AzureRmADApplication -DisplayNameStartWith $novaAppName
    $servicePrincipal = Get-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId

    $novaAppName = "configgen$name"
    $app = Get-AzureRmADApplication -DisplayNameStartWith $novaAppName
    $servicePrincipalConfiggen = Get-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId

    $SparkManagedIdentity = Get-AzureRmADServicePrincipal  -DisplayName SparkManagedIdentity$name
    $vmss = Get-AzureRmADServicePrincipal  -DisplayName D3$name 

    Set-AzureRmKeyVaultAccessPolicy -VaultName "$NovaServicesKVName" -ObjectId $servicePrincipal.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$NovaServicesKVName" -ObjectId $servicePrincipalConfiggen.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$NovaServicesKVName" -ObjectId $SparkManagedIdentity.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$NovaServicesKVName" -ObjectId $vmss.Id -PermissionsToSecrets Get,List,Set

    Set-AzureRmKeyVaultAccessPolicy -VaultName "$NovaSparkKVName" -ObjectId $servicePrincipal.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$NovaSparkKVName" -ObjectId $servicePrincipalConfiggen.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$NovaSparkKVName" -ObjectId $SparkManagedIdentity.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$NovaSparkKVName" -ObjectId $vmss.Id -PermissionsToSecrets Get,List,Set
}

Function GenerateSSLCertAndAddToSF([System.String]$certname = '')
{
 	$vaultname = "novasfKV$name"
    $clustername = "novasf-$name" 
    $subject = "CN=$kvName"+ ".$resourceLocationForServiceFabric" + ".cloudapp.azure.com";
    $certpw = "password"
	# $groupname = "$resourceGroupName"
	
	# $ExistingPfxFilePath = $CertsPath + "\$certname"

#   $cert
#    if (!$CertsPath) {
#        $cert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation cert:\LocalMachine\My
# 
#    }
#    else {
#        $path = $CertsPath + "\$certName.cer"
#        $cert = Import-Certificate -CertStoreLocation cert:\LocalMachine\My -FilePath $path
#    }
    
    # Export the cert to a PFX with password
#    $password = ConvertTo-SecureString $certpw -AsPlainText -Force
#    Export-PfxCertificate -Cert "cert:\LocalMachine\My\$($cert.Thumbprint)" -FilePath $certFileName -Password $password

    $certFileName = "$certname.pfx"
    $path = $PSScriptRoot + "\Certs\$certFileName"

    $bytes = [System.IO.File]::ReadAllBytes($path)
    $base64 = [System.Convert]::ToBase64String($bytes)

    $jsonBlob = @{
       data = $base64
       dataType = 'pfx'
       password = $certpw
       } | ConvertTo-Json

    $contentbytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBlob)
    $content = [System.Convert]::ToBase64String($contentbytes)

    $secretValue = ConvertTo-SecureString -String $content -AsPlainText -Force

    # Upload the certificate to the key vault as a secret
    Write-Host "Writing secret to $certname1 in vault $vaultname"
    $secret = Set-AzureKeyVaultSecret -VaultName $vaultname -Name $certname -SecretValue $secretValue

    # Add a certificate to all the VMs in the cluster.
    Add-AzureRmServiceFabricApplicationCertificate -ResourceGroupName $resourceGroupName -Name $clustername -SecretIdentifier $secret.Id -Verbose
}

Function OpenPort()
{
    $probename = "AppPortProbe6"
	$rulename = "AppPortLBRule6"
	$port = 443
	
	# Get the load balancer resource
	$resource = Get-AzureRmResource | Where {$_.ResourceGroupName -eq $resourceGroupName -and $_.ResourceType -eq "Microsoft.Network/loadBalancers"}
	$slb = Get-AzureRmLoadBalancer -Name $resource.Name -ResourceGroupName $resourceGroupName
	
	# Add a new probe configuration to the load balancer
	$slb | Add-AzureRmLoadBalancerProbeConfig -Name $probename -Protocol Tcp -Port $port -IntervalInSeconds 15 -ProbeCount 2
	
	# Add rule configuration to the load balancer
	$probe = Get-AzureRmLoadBalancerProbeConfig -Name $probename -LoadBalancer $slb
	$slb | Add-AzureRmLoadBalancerRuleConfig -Name $rulename -BackendAddressPool $slb.BackendAddressPools[0] -FrontendIpConfiguration $slb.FrontendIpConfigurations[0] -Probe $probe -Protocol Tcp -FrontendPort $port -BackendPort $port
	
	# Set the goal state for the load balancer
    $slb | Set-AzureRmLoadBalancer 
}

Function SetupSF()
{
    $novaprodsfSSLCert = GenerateSSLCertAndAddToSF -certName "novasfssl$name"
    OpenPort
}


#******************************************************************************
# Script body
# Execution begins here
#******************************************************************************
$ErrorActionPreference = "Continue"

# sign in
Write-Host "Logging in...";
#$acc = Login-AzureRmAccount;
 $acc = Connect-AzureAD;
# $tenantId = $acc.Tenant.Id.Guid
# $tenantName = $acc.Tenant.Domain
# $userId = (Get-AzureADUser -ObjectId $acc.Account.Id).ObjectId

$tenantId = "72f988bf-86f1-41af-91ab-2d7cd011db47"
$tenantName = "microsoft.onmicrosoft.com"
$userId = "3e5b292a-d0c3-4169-8538-62bb27000d58"
# select subscription
Write-Host "Selecting subscription '$subscriptionId'";
Select-AzureRmSubscription -SubscriptionID $subscriptionId;

# Register RPs
$resourceProviders = @("microsoft.cache","microsoft.compute","microsoft.documentdb","microsoft.eventhub","microsoft.insights","microsoft.keyvault","microsoft.network","microsoft.servicefabric","microsoft.storage","microsoft.web");
if($resourceProviders.length) {
    Write-Host "Registering resource providers"
    foreach($resourceProvider in $resourceProviders) {
# TODO uncomment below
#        RegisterRP($resourceProvider);
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
    $resourceGroupLocation = $resourceGroup.Location
}

#$azureADApplication = GenerateAzureADApplication;

# Start the deployment
Write-Host "Starting deployment...";

$templateFilePath = "template.json"
# Initialize
Init -templatePath $templateFilePath

if(Test-Path "temp_$templateFilePath") {
    # New-AzureRmResourceGroupDeployment -Debug -ResourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePath";    
    # New-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePath";
}

# Certs
$novaprodsfCert = GenerateCertsAndImportKeyVault -certName "novasf$name"
$novaprodsfreverseproxyCert = GenerateCertsAndImportKeyVault -certName "novasfreverseproxy$name"

$azureADApplication = GenerateAzureADApplication -novaAppName "novaapp$name" -websiteName "nova$name";
$azureADApplicationConfiggen = GenerateAzureADApplication -novaAppName "configgen$name";
$azureADAppSecret = SetAzureADAppSecret -AppName "novaapp$name";
$azureADAppSecretConfiggen = SetAzureADAppSecret -AppName "configgen$name";

# Start SF deployment
Write-Host "Starting SF deployment...";
$templateFilePathForSF = "sf-template.json"
Init -templatePath $templateFilePathForSF
if(Test-Path "temp_$templateFilePathForSF")
{
#    New-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePathForSF";
}

# Processing
$dbConRaw = Invoke-AzureRmResourceAction -Action listConnectionStrings `
    -ResourceType "Microsoft.DocumentDb/databaseAccounts" `
    -ApiVersion "2015-04-08" `
    -ResourceGroupName $resourceGroupName `
    -Name $DBName `
    -force

$dbCon = $dbConRaw.connectionStrings[0].connectionString

$novaopsconnectionString = ''
$storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $novaconfigsBlobAccountName;
if ($storageAccount.Context.ConnectionString -match '(AccountName=.*)')
{
    $connectionString = $Matches[0]
    $novaopsconnectionString = "DefaultEndpointsProtocol=https;$connectionString;EndpointSuffix=core.windows.net"
}    


SetupSF

# Secrets
SetupSecrets


# Spark
AddScriptActions

# Blob
SetupBlob

# cosmosDB
SetupCosmosDB

# Access Policies
SetupKVAccess
