
# example usage: powershell -ExecutionPolicy Bypass -File docker-dl.ps1 python:3.12-bookworm


# Workaround for SelfSigned Cert an force TLS 1.2
add-type @"
	using System.Net;
	using System.Security.Cryptography.X509Certificates;
	public class TrustAllCertsPolicy : ICertificatePolicy {
		public bool CheckValidationResult(
		ServicePoint srvPoint, X509Certificate certificate,
		WebRequest request, int certificateProblem) {
			return true;
		}
	}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


#Param
#  (
#     [parameter(Position=0, Mandatory=$true)]
#     [String]
#     $ImageTag
#   )


$image, $tag = $args[0].split(':')
#$tgzname = $args[0] -replace '[\\/":*?<>|]'

# assume library if path not specified
if (-not $image.Contains("/")) {
	$image = "library/"+$image
}

$simplename = (-join($image.split("/")[1], $tag)) -replace '[\\/":*?<>|]'
$tgzname = (-join($simplename, ".tgz"))
#$tgzname = (-join($image.split("/")[1], $tag, ".tgz")) -replace '[\\/":*?<>|]'

$imageuri = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${image}:pull" 
$taguri = "https://registry-1.docker.io/v2/${image}/manifests/${tag}"
$bloburi = "https://registry-1.docker.io/v2/${image}/blobs/" 

# powershell doesn't seem to have a GetTempDirectory() option.
# So get a file, delete it, and use it's name.  better way?
$tmpDir = [System.IO.Path]::GetTempFileName()
Remove-Item $tmpDir
$null = New-Item -Path $tmpDir -ItemType 'Directory'
if (-Not (Test-Path -Path "$tmpDir")) {
	Write-Output "Unable to create tmp directory"
	exit 1
}
# token request 
$token = Invoke-WebRequest -Uri $imageuri | ConvertFrom-Json | Select -expand token 

# getting image manifest 
$headers = @{} 
$headers.add("Authorization", "Bearer $token") 
# this header is needed to get manifest in correct format: https://docs.docker.com/registry/spec/manifest-v2-2/ 
$headers.add("Accept", "application/vnd.docker.distribution.manifest.v2+json") 
$manifest = Invoke-Webrequest -Headers $headers -Method GET -Uri $taguri | ConvertFrom-Json 

# downloading config json 
$configSha = $manifest | Select -expand config | Select -expand digest 
$config = "$tmpDir\config.json" 
Invoke-Webrequest -Headers @{Authorization="Bearer $token"} -Method GET -Uri $bloburi$configSha -OutFile $config 

# generating manifest.json 
$manifestJson = @{} 
$manifestJson.add("Config", "config.json") 
$manifestJson.add("RepoTags",@("${image}:${tag}")) 

# downloading layers 
$layers = $manifest | Select -expand layers | Select -expand digest 
$blobtmp = "$tmpDir\blobtmp" 

#downloading blobs 
$layersJson = @() 
foreach ($blobelement in $layers) { 
	# making so name doesnt start with 'sha256:' 
	$fileName = "$blobelement.gz" -replace 'sha256:' 
	$newfile = "$tmpDir\$fileName" 
	$layersJson += @($fileName) 

	# token expired after 5 minutes, so requesting new one for every blob just in case 
	$token = Invoke-WebRequest -Uri $imageuri | ConvertFrom-Json | Select -expand token 
	
	Invoke-Webrequest -Headers @{Authorization="Bearer $token"} -Method GET -Uri $bloburi$blobelement -OutFile $blobtmp 
	
	Copy-Item $blobtmp $newfile -Force -Recurse 
} 

# removing temporary blob 
Remove-Item $blobtmp 

# saving manifest.json 
$manifestJson.add("Layers", $layersJson) 
ConvertTo-Json -Depth 5 -InputObject @($manifestJson) | Out-File -Encoding ascii "$tmpDir\manifest.json" 

$null = Start-Process -NoNewWindow -Wait -FilePath "C:\windows\system32\tar.exe" -ArgumentList "-cvzf $tgzname -C $tmpDir ."
Remove-Item $tmpDir -Force -Recurse

# postprocessing
echo "To load into docker run:"
echo "'docker load -i $tgzname'"
echo "To load into WSL run:"
echo "'wsl.exe --import $simplename %LOCALAPPDATA%\Packages\$simplename $tgzname'"
