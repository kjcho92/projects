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
    [Parameter(Mandatory=$True)]
    [string]
    $paramFile,

    [string]
    $subscriptionId,

    [string]
    $certPassword,

    [string]
    $novaSparkPassword,

    [string]
    $resourceGroupName,

    [string]
    $productName,

    [string]
    $resourceGroupLocation,

    #[Parameter(Mandatory=$True, HelpMessage="Location for Microsoft.Insights")]
    [ValidateSet("EastUS", "SouthCentralUS", "NorthEurope", "WestEurope", "SoutheastAsia", "WestUS2", "CanadaCentral", "CentralIndia")]
    [string]
    $resourceLocationForMicrosoftInsights,

    #[Parameter(Mandatory=$True, HelpMessage="Location for Microsoft.ServiceFabric")]
    [string]
    $resourceLocationForServiceFabric,

    #[Parameter(Mandatory=$True)]
    [ValidateScript({Test-Path $_ })]
    [string]
    $deploymentFilePath,

    [string]
    $resourceCreation,

    [string]
    $sparkCreation,

    [string]
    $serviceFabricCreation,

    [string]
    $generateAndUseSelfSignedCerts,

    [string]
    [ValidateScript({Test-Path $_ })]
    $mainCert,

    [string]
    [ValidateScript({Test-Path $_ })]
    $reverseProxyCert,

    [string]
    [ValidateScript({Test-Path $_ })]
    $sslCert
)

$ErrorActionPreference = "stop"

Get-Content $ParamFile | Foreach-Object{
    if ($_.startsWith('#') -or !$_) {
        return    
    }
    $var = $_.Split('=')
    set-Variable -Name $var[0] -Value $var[1]
 }

$name = $productName.ToLower()

if (!$serviceFabricName) { 
    $serviceFabricName = "$name"
}

if (!$novaServiceAppName) {
    $novaServiceAppName = "serviceapp-$name" 
}

if (!$novaAppName) {
    $novaAppName = "novaapp-$name"
}

$novaServicesKVName = "ServicesKV$name"
$novaSparkKVName = "SparkKV$name"
$novaSparkRDPKVName = "SparkRDPKV$name"
$novaFabricRDPKVName = "FabricRDPKV$name"
$novasfKVName = "SFKV$name"

# $certPath = "Certs"

$docDBName = "$name"

$websiteName = "$name"
$sparkName = "$name"

$appInsightsName = "$name"
$appInsightsNameWeb = "$nameweb"
$redisName = "$name"
$eventHubNamespaceName = "novametricseventhub$name"
$eventHubEmailNamespaceName = "novaemailseventhub$name"
$novaSparkBlobAccountName = "$sparkName" + "spark"
$novaconfigsBlobAccountName = "novaconfigs$name" 


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

Function CheckFilePath()
{
    Test-Path "$deploymentFilePath\Blob"
    Test-Path "$deploymentFilePath\CosmosDB"
    Test-Path "$deploymentFilePath\scripts"
}

Function TranslateTokens([System.String]$Source = '')
{
    $newStr = $Source.Replace('$websiteName', $websiteName )
    $newStr = $newStr.Replace('$sparkName', $sparkName )
    $newStr = $newStr.Replace('$$appInsightsNameWeb', $appInsightsNameWeb )
    $newStr = $newStr.Replace('$appInsightsName', $appInsightsName )
    $newStr = $newStr.Replace('$redisName', $redisName )
    $newStr = $newStr.Replace('$novaSparkRDPKVName', $novaSparkRDPKVName )
    $newStr = $newStr.Replace('$novaFabricRDPKVName', $novaFabricRDPKVName )
    $newStr = $newStr.Replace('$novaServicesKVName', $novaServicesKVName )
    $newStr = $newStr.Replace('$novaSparkKVName', $novaSparkKVName )
    $newStr = $newStr.Replace('$novasfKVName', $novasfKVName )
    $newStr = $newStr.Replace('$docDBName', $docDBName )
    $newStr = $newStr.Replace('$eventHubNamespaceName', $eventHubNamespaceName )
    $newStr = $newStr.Replace('$serviceFabricName', $serviceFabricName )
    $newStr = $newStr.Replace('$novaSparkBlobAccountName', $novaSparkBlobAccountName )
    $newStr = $newStr.Replace('$novaconfigsBlobAccountName', $novaconfigsBlobAccountName )

    # Template
    $newStr = $newStr.Replace('$subscriptionId', $subscriptionId )
    $newStr = $newStr.Replace('$resourceGroup', $resourceGroupName )
    $newStr = $newStr.Replace('$resourceLocationForMicrosoftInsights', $resourceLocationForMicrosoftInsights )

    $newStr = $newStr.Replace('$novaSparkPassword', $novaSparkPassword )
    $newStr = $newStr.Replace('$tenantId', $tenantId )
    $newStr = $newStr.Replace('$userId', $userId )

    # Blob
    $newStr = $newStr.Replace('$eventhubMetricDefaultConnectionString', $eventhubMetricDefaultConnectionString )

    # CosmosDB
    $newStr = $newStr.Replace('$novaopsconnectionString', $novaopsconnectionString )
    $newStr = $newStr.Replace('$novaSparkPassword', $novaSparkPassword )
    $newStr = $newStr.Replace('$configgenClientId', $azureADApplicationConfiggen.ApplicationId )
    $newStr = $newStr.Replace('$configgenTenantId', $tenantName )

    $aiResource = Get-AzureRmApplicationInsights -resourceGroupName $resourceGroupName -Name $appInsightsName -ErrorAction SilentlyContinue
    $newStr = $newStr.Replace('$appinsightkey', $aiResource.InstrumentationKey )    

    # SF Template
    $newStr = $newStr.Replace('$novaprodsfCertThumbprint', $novaprodsfCert.Certificate.Thumbprint )
    $newStr = $newStr.Replace('$novaprodsfCertSecretId', $novaprodsfCert.SecretId )
    $newStr = $newStr.Replace('$novaprodsfreverseProxyCertThumbprint', $novaprodsfreverseProxyCert.Certificate.Thumbprint )
    $newStr = $newStr.Replace('$novaprodsfreverseProxyCertSecretId', $novaprodsfreverseProxyCert.SecretId )
    $newStr = $newStr.Replace('$resourceLocationForServiceFabric', $resourceLocationForServiceFabric )

    $newStr = $newStr.Replace('$resourceLocation', $resourceGroupLocation )

    $newStr = $newStr.Replace('$name', $name )

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

# aad
Function GenerateAzureADApplication([System.String]$appName = '', [System.String]$websiteName = '')
{
    # New-AzureADApplication -DisplayName "nova$name"  -IdentifierUris "https://nova$name.azurewebsites.net" -ReplyUrls "https://nova$name.azurewebsites.net/authReturn"
    $app = Get-AzureRmADApplication -DisplayNameStartWith $appName
    if (!$app)
    {
        if ($websiteName){
            $app = New-AzureRmADApplication  -DisplayName $appName -IdentifierUris "https://$tenantName/$appName" -ReplyUrls "https://$websiteName.azurewebsites.net/authReturn"
        }
        else {
            $app = New-AzureRmADApplication  -DisplayName $appName -IdentifierUris "https://$tenantName/$appName" 
            
            $cer = $novaprodsfCert.Certificate
            $certValue = [System.Convert]::ToBase64String($cer.GetRawCertData())
    
            New-AzureRmADAppCredential -ApplicationId $app.ApplicationId -CertValue $certValue -StartDate $cer.NotBefore -EndDate $cer.NotAfter
        }
    }
    
    if ($websiteName)
    {
        $urls = $app.ReplyUrls
        $urls.Add("https://$websiteName.azurewebsites.net/authReturn")
        Set-AzureRmADApplication -ObjectId $app.ObjectId -ReplyUrl $urls -ErrorAction SilentlyContinue
    }


    $servicePrincipal = Get-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId
    if (!$servicePrincipal)
    {
         $servicePrincipal = New-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId
    }

    $app
}

Function GenerateSelfSignedCerts()
{
    $certNames = @( "$mainCert", "$reverseProxyCert", "$sslCert" )

    $todaydt = Get-Date
    $2years = $todaydt.AddYears(2)

    $certNames | foreach {
        $certFileName = $_
        $clustername = "$serviceFabricName" 
        $subject = "CN=$clustername"+ ".$resourceLocationForServiceFabric" + ".cloudapp.azure.com";     
 
        $certFilePath = $PSScriptRoot + "\$certFileName"
        $password = ConvertTo-SecureString $certPassword -AsPlainText -Force
        

        $cert = New-SelfSignedCertificate -Subject $subject -notafter $2years  -CertStoreLocation cert:\LocalMachine\My
        
        # Export the cert to a PFX with password
        Export-PfxCertificate -Cert "cert:\LocalMachine\My\$($cert.Thumbprint)" -FilePath $certFilePath -Password $password
        
        Import-PfxCertificate -FilePath $certFilePath -CertStoreLocation cert:\CurrentUser\My -Password $password
    }
}

Function ImportingCerts()
{
    $certNames = @( "$mainCert", "$reverseProxyCert", "$sslCert" )

    $certNames | foreach {

        $certFilePath =  $_.Replace("""", "")
        
        if (!(Test-Path "$certFilePath")){
            Write-Error "$certFilePath does not exist" -ErrorAction Stop
        }

        $certFileEXtension = (Get-Item $certFilePath).Extension.ToLower()
        $certFileName = (Get-Item $certFilePath).Name
        $certFilePathDest = $PSScriptRoot + "\$certFileName"
                
        if ($certFileEXtension -ne '.pfx') {
            Write-Error "Please use a pfx cert" -ErrorAction Stop
        }

        $password = ConvertTo-SecureString $certPassword -AsPlainText -Force

        Import-PfxCertificate -FilePath $certFilePath -CertStoreLocation cert:\LocalMachine\My -Password $password
        Import-PfxCertificate -FilePath $certFilePath -CertStoreLocation cert:\CurrentUser\My -Password $password
        
        Copy-Item -Path $certFilePath -Destination $certFilePathDest
        # Export the cert to a PFX with password
        # Export-PfxCertificate -Cert "cert:\LocalMachine\My\$($cert.Thumbprint)" -FilePath $certFilePathDest -Password $password
    }
}

Function ImportCertsToKeyVault([System.String]$certName = '')
{
    $certName = $certName.Replace("""", "")
    $certFileName = (Get-Item $certName).Name
    $certBaseName = (Get-Item $certName).BaseName
    $password = ConvertTo-SecureString $certPassword -AsPlainText -Force
    
    $certFilePath = $PSScriptRoot + "\$certFileName"

    # Upload to Key Vault
    $cert = Import-AzureKeyVaultCertificate -VaultName $novasfKVName -Name $certBaseName -FilePath $certFilePath -Password $password
    $cert
}

Function AddScriptActions()
{
    $clusterName = "$sparkName";
    $scriptActionName = "StartMSIServer";

    $scAction = Get-AzureRmHDInsightScriptActionHistory -ClusterName $clusterName
    if (($scAction.Name -eq "$scriptActionName") -and ($scAction.Status -eq 'succeeded')) {
        return
    }

    $storageAccount = Get-AzureRmStorageAccount -resourceGroupName $resourceGroupName -Name $novaSparkBlobAccountName;
    $ctx = $storageAccount.Context;

    if ($ctx) {
        $scriptActionUri = "https://$novaSparkBlobAccountName.blob.core.windows.net/scripts/novastartmsiserverservice.sh";

        $containerName = "scripts";
        $sourceFileRootDirectory = "$deploymentFilePath\scripts";
        $nodeTypes = "headnode", "workernode"
    
        try
        {
            New-AzureStorageContainer -Name $containerName -Context $ctx -ErrorAction SilentlyContinue
        }
        catch {}

        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) 
        {
            $rawData = Get-Content -Raw -Path $x.fullname
            $rawData = TranslateTokens -Source $rawData
            Set-Content -Path $x.name -Value $rawData

            Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            Set-AzureStorageBlobContent -File $x.name -Container $containerName -Context $ctx -Force:$Force | Out-Null
        }

        Submit-AzureRmHDInsightScriptAction -ClusterName $clusterName `
            -Name $scriptActionName `
            -Uri $scriptActionUri `
            -NodeTypes $nodeTypes `
            -PersistOnSuccess
    }
}

Function SetupCosmosDB()
{
    # $storageAccount = Get-AzureRmStorageAccount -resourceGroupName $resourceGroupName -Name $novaconfigsBlobAccountName

  
    Connect-Mdbc -ConnectionString $dbCon -DatabaseName "production"
    $colnames = @(
        "sparkJobTemplates"
        # ,
        # "azureStorages",
        # "commons",
        # "metricSources",
        # "metricWidgets",
        # "novaFlowConfigs",
        # "products",
        # "sparkClusters",
        # "sparkJobs",
        # "sparkJobTemplates"
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
    
    $templatePath = "$deploymentFilePath\CosmosDB"; #path to templates
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
                $_ | ConvertTo-Json -Depth 3 | Set-Content t.json
                $input = Import-MdbcData t.json -FileFormat Json
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

Function SetupBlobHelper([System.String]$containerName = '', [System.String]$saname = '', [System.String]$translate = '')
{
    $storageAccount = Get-AzureRmStorageAccount -resourceGroupName $resourceGroupName -Name $saname;
    $ctx = $storageAccount.Context;

    if ($ctx)
    {
        $sourceFileRootDirectory = "$deploymentFilePath\Blob\$containerName"
        $scriptRoot = "$deploymentFilePath\Blob\$containerName"
        # $scriptRoot = $PSScriptRoot + "\Blob\$containerName";
        
        New-AzureStorageContainer -Name $containerName -Context $ctx -ErrorAction SilentlyContinue
        
        $filesToUpload = Get-ChildItem $sourceFileRootDirectory -Recurse -File

        foreach ($x in $filesToUpload) {
            $targetPath = ($x.fullname.Substring($scriptRoot.Length + 1)).Replace("\", "/")
            Write-Verbose "Uploading $("\" + $x.fullname.Substring($sourceFileRootDirectory.Length + 1)) to $($container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $targetPath)"
            
            if (!$translate) {
                Set-AzureStorageBlobContent -File $x.fullname -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
            }            
            else {
                $rawData = Get-Content -Raw -Path $x.fullname
                TranslateTokens -Source $rawData | Set-Content t.json
                
                Set-AzureStorageBlobContent -File t.json -Container $containerName -Blob $targetPath -Context $ctx -Force:$Force | Out-Null
            }
        }
    }   
}

Function SetupBlob()
{
    SetupBlobHelper -containerName  "deployment" -saname $novaconfigsBlobAccountName
    SetupBlobHelper -containerName  "rules" -saname $novaconfigsBlobAccountName
    SetupBlobHelper -containerName  "centralprocessing"  -saname $novaconfigsBlobAccountName -translate 'y'
    SetupBlobHelper -containerName  "deployment" -saname $novaSparkBlobAccountName
}

Function SetupSecretHelper([System.String]$VaultName = '', [System.String]$SecretName = '', [System.String]$Value = '')
{    
    $secret = ConvertTo-SecureString -String $Value -AsPlainText -Force
    Set-AzureKeyVaultSecret -VaultName $VaultName -Name $SecretName -SecretValue $secret
}

Function SetupSecrets()
{
    #novaServicesKVName

    $vaultName = "$novaServicesKVName"
    $prefix = "novaconfiggen-";

    $secretName = "novaconfigs$name" + "ConnectionString" # Needed?
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaopsconnectionString

    $secretName = $prefix + "novaflowconfigs";
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $dbCon

    $secretName = $prefix + "novaflowconfigsdatabasename"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "production"

    $secretName = $prefix + "$sparkName" + $certPassword
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaSparkPassword

    $secretName = $prefix + "novaconfigs$name" + "-blobconnectionstring"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaopsconnectionString

    $secretName = $prefix + "aiInstrumentationKey"    
    $aiKey = (Get-AzureRmApplicationInsights -resourceGroupName $resourceGroupName -Name $appInsightsName).InstrumentationKey
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $aiKey

    $secretName = $prefix + "clientsecret"    
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $azureADAppSecretConfiggen.Value

    $secretName = $prefix + "-eventbubnamespaceconnectionstring"     
    $tValue = (Invoke-AzureRmResourceAction -ResourceGroupName NovaProd -ResourceType Microsoft.EventHub/namespaces/AuthorizationRules -ResourceName novametricseventhubkcnova/RootManageSharedAccessKey -Action listKeys -ApiVersion 2015-08-01 -Force).primaryConnectionString
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue

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
    $sfName = "$serviceFabricName"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "https://$sfName"+ ".$resourceLocationForServiceFabric" + ".cloudapp.azure.com"

    $secretName = $prefix + "datahubResourceId"
   #$novaAppName = "novaapp$name"
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "https://$tenantName/$novaServiceAppName"

    $secretName = $prefix + "mongoDbUrl"    
    $tValue = $dbCon.Replace("/?ssl=true", "/production?ssl=true")
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue

    $secretName = $prefix + "redisDataConnectionString" 
    $redisKey = (Get-AzureRmRedisCacheKey -Name $redisName -resourceGroupName $resourceGroupName).PrimaryKey
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "$redisName.redis.cache.windows.net:6380,password=$redisKey,ssl=True,abortConnect=False"
    
    $secretName = $prefix + "sessionSecret"       
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "test"

    $secretName = $prefix + "subscriptionId"       
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $subscriptionId

    $secretName = $prefix + "tenantName"    
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tenantName

    #novaServicesKVName

    $vaultName = "$novaSparkKVName"
    $prefix = "";
    
    $secretName = $prefix + "nova-sa-" + $novaconfigsBlobAccountName    
    $storageAccount = Get-AzureRmStorageAccount -resourceGroupName $resourceGroupName -Name $novaconfigsBlobAccountName;
    $tValue = ""
    if ($storageAccount.Context.ConnectionString -match 'AccountKey=(.*)')
    {
        $tValue = $Matches[1].Replace("AccountKey=", "")
    }

    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue
    
    $secretName = $prefix + "metric-eventhubconnectionstring"    
    $tValue = (Get-AzureRmEventHubKey -resourceGroupName $resourceGroupName -NamespaceName "$eventHubNamespaceName" -EventHubName novametricseventhub -AuthorizationRuleName manage).PrimaryConnectionString
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue
    
    $secretName = $prefix + "metric-eventhubdefaultconnectionstring"    
    $tValue = (Get-AzureRmEventHubKey -resourceGroupName $resourceGroupName -NamespaceName "$eventHubNamespaceName" -EventHubName novametricseventhubdefault -AuthorizationRuleName manage).PrimaryConnectionString
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $tValue
       
    # novaSparkRDPKVName
    $vaultName = "$novaSparkRDPKVName"
    $prefix = "";
    
    $secretName = $prefix + "sshuser" 
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaSparkPassword
        
    # novaFabricRDPKVName
    $vaultName = "$novaFabricRDPKVName"
    $prefix = "";
    
    $secretName = $prefix + "novasfadminpassword" 
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value $novaSparkPassword
    
    $secretName = $prefix + "novasfadminuser" 
    SetupSecretHelper -VaultName $vaultName -SecretName $secretName -Value "novapd"    
}


Function SetupKVAccess()
{
    # $novaAppName = "novaapp$name"
    # $app = Get-AzureRmADApplication -DisplayNameStartWith $novaAppName
    # $servicePrincipal = Get-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId

    #	$resource = Get-AzureRmResource | Where {$_.resourceGroupName -eq $resourceGroupName -and $_.ResourceType -eq "Microsoft.Web/sites"}
    # Get ObjectId of web app
    $app = Get-AzureRmADServicePrincipal  -DisplayName "$websiteName"
    $servicePrincipal = Get-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId

    # $novaAppName = "configgen$name"
    $app = Get-AzureRmADApplication -DisplayNameStartWith $novaServiceAppName
    $servicePrincipalConfiggen = Get-AzureRmADServicePrincipal -ApplicationId $app.ApplicationId

    $SparkManagedIdentity = Get-AzureRmADServicePrincipal  -DisplayName SparkManagedIdentity$name
    $vmss = Get-AzureRmADServicePrincipal  -DisplayName D3$name 

    Set-AzureRmKeyVaultAccessPolicy -VaultName "$novaServicesKVName" -ObjectId $servicePrincipal.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$novaServicesKVName" -ObjectId $servicePrincipalConfiggen.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$novaServicesKVName" -ObjectId $SparkManagedIdentity.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$novaServicesKVName" -ObjectId $vmss.Id -PermissionsToSecrets Get,List,Set

    Set-AzureRmKeyVaultAccessPolicy -VaultName "$novaSparkKVName" -ObjectId $servicePrincipal.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$novaSparkKVName" -ObjectId $servicePrincipalConfiggen.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$novaSparkKVName" -ObjectId $SparkManagedIdentity.Id -PermissionsToSecrets Get,List,Set
    Set-AzureRmKeyVaultAccessPolicy -VaultName "$novaSparkKVName" -ObjectId $vmss.Id -PermissionsToSecrets Get,List,Set
}

Function ImportSSLCertToSF([System.String]$certname = '')
{
    $certName = $certName.Replace("""", "")
    $certFileName = (Get-Item $certName).Name
    $certBaseName = (Get-Item $certName).BaseName
    $certFilePath = $PSScriptRoot + "\$certFileName"
    $clustername = "$serviceFabricName" 
# $groupname = "$resourceGroupName"
	
	# $ExistingPfxFilePath = $certPath + "\$certname"

    $bytes = [System.IO.File]::ReadAllBytes($certFilePath)
    $base64 = [System.Convert]::ToBase64String($bytes)

    $jsonBlob = @{
       data = $base64
       dataType = 'pfx'
       password = $certPassword
       } | ConvertTo-Json

    $contentbytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBlob)
    $content = [System.Convert]::ToBase64String($contentbytes)

    $secretValue = ConvertTo-SecureString -String $content -AsPlainText -Force

    # Upload the certificate to the key vault as a secret
    Write-Host "Writing secret to $certBaseName in vault $novasfKVName"

    $secret = Set-AzureKeyVaultSecret -VaultName $novasfKVName -Name $certBaseName -SecretValue $secretValue

    #do {
    #    try {
    #        $secret = Set-AzureKeyVaultSecret -VaultName $novasfKVName -Name $certBaseName -SecretValue $secretValue -ErrorAction stop
    #    }
    #    catch {
    #        Write-Error "error on setting up SSL secret to $novasfKVName. Retrying..."
    #    }
    #} while (!$secret)

    # Add a certificate to all the VMs in the cluster.
    Add-AzureRmServiceFabricApplicationCertificate -resourceGroupName $resourceGroupName -Name $clustername -SecretIdentifier $secret.Id -Verbose
}

Function OpenPort()
{
    $probename = "AppPortProbe6"
	$rulename = "AppPortLBRule6"
	$port = 443
	
	# Get the load balancer resource
	$resource = Get-AzureRmResource | Where {$_.resourceGroupName -eq $resourceGroupName -and $_.ResourceType -eq "Microsoft.Network/loadBalancers"}
	$slb = Get-AzureRmLoadBalancer -Name $resource.Name -resourceGroupName $resourceGroupName
	
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
    ImportSSLCertToSF -certName "$sslCert"
    OpenPort
}

#******************************************************************************
# Script body
# Execution begins here
#******************************************************************************
$ErrorActionPreference = "Continue"

Push-Location $PSScriptRoot

# Preparing certs...
if ($generateAndUseSelfSignedCerts -eq 'y') {
    Write-Host "Generating SelfSigned certs..."

    $mainCert = "novasf$name.pfx"
    $reverseProxyCert = "novasfreverseproxy$name.pfx"
    $sslCert = "novasfssl$name.pfx"

    GenerateSelfSignedCerts
}
else {
        if (!$mainCert) {
            $mainCert = Read-Host "MainCert filepath"        
        }
        
        if (!$reverseProxyCert) {
            $reverseProxyCert = Read-Host "ReverseProxyCert filepath"
        }
        if (!$reverseProxyCert) {
            $reverseProxyCert = Read-Host "SSLCert filepath"
        }
        Write-Host "Importing existing certs.."
        ImportingCerts
}

CheckFilePath

# sign in
Write-Host "Logging in...";
#  $acc = Connect-AzureAD;
#  $tenantId = $acc.Tenant.Id.Guid
#  $tenantName = $acc.Tenant.Domain
#  $userId = (Get-AzureADUser -ObjectId $acc.Account.Id).ObjectId

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
    Write-Host "Using existing resource group '$resourceGroupName'"
    $resourceGroupLocation = $resourceGroup.Location
}



# Start the deployment
Write-Host "Starting deployment...";

$templateFilePath = "template.json"
# Initialize
Init -templatePath $templateFilePath

if((Test-Path "temp_$templateFilePath") -and ($resourceCreation -eq 'y')) {
    # New-AzureRmResourceGroupDeployment -Debug -resourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePath";    
    New-AzureRmResourceGroupDeployment -resourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePath";
}

Write-Host "Starting Spark deployment...";

$templateFilePath = "spark-template.json"
# Initialize
Init -templatePath $templateFilePath

if((Test-Path "temp_$templateFilePath") -and ($sparkCreation -eq 'y')) {
    # New-AzureRmResourceGroupDeployment -Debug -resourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePath";    
    New-AzureRmResourceGroupDeployment -resourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePath";
}

Write-Host "processing certs...";
# Certs
$novaprodsfCert = ImportCertsToKeyVault -certName "$mainCert"
$novaprodsfreverseProxyCert = ImportCertsToKeyVault -certName "$reverseProxyCert"
# $novaprodsfSSLCert = ImportCertsToKeyVault -certName "$sslCert"

#aad
$azureADApplication = GenerateAzureADApplication -appName "$novaAppName" -websiteName "$websiteName";
$azureADApplicationConfiggen = GenerateAzureADApplication -appName "$novaServiceAppName";
$azureADAppSecret = SetAzureADAppSecret -AppName "$novaAppName";
$azureADAppSecretConfiggen = SetAzureADAppSecret -AppName "$novaServiceAppName";

# Start SF deployment
Write-Host "Starting SF deployment...";
$templateFilePath = "sf-template.json"
Init -templatePath $templateFilePath
if((Test-Path "temp_$templateFilePath") -and ($serviceFabricCreation -eq 'y' ))
{
    New-AzureRmResourceGroupDeployment -resourceGroupName $resourceGroupName -TemplateFile "temp_$templateFilePath";
}

# Processing
$dbConRaw = Invoke-AzureRmResourceAction -Action listConnectionStrings `
    -ResourceType "Microsoft.DocumentDb/databaseAccounts" `
    -ApiVersion "2015-04-08" `
    -resourceGroupName $resourceGroupName `
    -Name $docDBName `
    -force

$dbCon = $dbConRaw.connectionStrings[0].connectionString

$novaopsconnectionString = ''
$storageAccount = Get-AzureRmStorageAccount -resourceGroupName $resourceGroupName -Name $novaconfigsBlobAccountName;
if ($storageAccount.Context.ConnectionString -match '(AccountName=.*)')
{
    $connectionString = $Matches[0]
    $novaopsconnectionString = "DefaultEndpointsProtocol=https;$connectionString;EndpointSuffix=core.windows.net"
}    

# Secrets
if ($setupSecrets -eq 'y') {
    Write-Host "Setting up Secrets...";
    SetupSecrets
}

# Spark
if ($addScriptActions -eq 'y') {
    Write-Host "Setting up ScriptActions...";
    AddScriptActions
}

# Blob
if ($setupBlob -eq 'y') {
    Write-Host "Setting up Blobs...";
    SetupBlob
}

# cosmosDB
if ($setupCosmosDB -eq 'y') {
    Write-Host "Setting up CosmosDB...";
    SetupCosmosDB
}

# Access Policies
if ($setupKVAccess -eq 'y') {
    Write-Host "Setting up KV access...";
    SetupKVAccess
}

# setup SF
if ($setupSF -eq 'y') {
    Write-Host "Setting up SF...";
    SetupSF
}

# can't have this as it will throw an error: Operation returned an invalid status code 'Conflict'
# ImportCertsToKeyVault -certName "$sslCert"
