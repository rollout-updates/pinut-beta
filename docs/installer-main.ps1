#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$manifestUrl = "https://script.google.com/macros/s/AKfycbwec0M06pJIfvnIQgkehojewob9pUbj7UMiPZDfUO492QP8G4uUMwISB5KH0PDS9juuQQ/exec?action=get_manifest"

$maximumAttempts = 3
$retryDelaySeconds = 66

# Create unique temp directory in Public folder to ensure elevated context access
$tempDirectory = Join-Path 'C:\Users\Public' ('PinutInstaller-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempDirectory -Force

$manifestFile = Join-Path $tempDirectory 'manifest.json'
# Pre-initialize so the finally block is safe even if parsing fails early
$downloadedFile = $null

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {
    Write-Host "Obtendo instruções do manifesto..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    # Download manifest
    Invoke-WebRequest -Uri $manifestUrl -OutFile $manifestFile -UseBasicParsing
    
    if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
        throw "Não foi possível baixar o manifesto de instalação."
    }
    
    $manifestInfo = Get-Item -LiteralPath $manifestFile -ErrorAction Stop
    if ($manifestInfo.Length -le 0) {
        throw "O manifesto de instalação baixado está vazio."
    }
    
    $manifestJson = Get-Content -Raw -LiteralPath $manifestFile
    $manifest = ConvertFrom-Json $manifestJson
    
    # Validate manifest structure and parameters strictly
    if ([string]::IsNullOrEmpty($manifest.version) -or 
        [string]::IsNullOrEmpty($manifest.source) -or 
        [string]::IsNullOrEmpty($manifest.filename) -or 
        [string]::IsNullOrEmpty($manifest.sha256)) {
        throw "Manifesto malformado ou campos vazios."
    }
    
    try {
        $uri = New-Object System.Uri($manifest.source)
        if ($uri.Scheme -ne 'https') {
            throw "Protocolo inválido na origem do manifesto."
        }
    }
    catch {
        throw "Erro ao processar a URL do manifesto: $_"
    }
    
    # URL de origem validada — atribuída à variável usada no loop de download
    $expectedSourceUrl = $manifest.source
    $downloadedFile = Join-Path $tempDirectory $manifest.filename
    
    if ($manifest.sha256.Length -ne 64 -or $manifest.sha256 -match '[^a-fA-F0-9]') {
        throw "Checksum SHA-256 inválido no manifesto."
    }
    
    $expectedHash = $manifest.sha256.Trim().ToUpperInvariant()
    $downloadedSuccessfully = $false
    
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        Write-Host "Tentativa $attempt de ${maximumAttempts}: Baixando componente..." -ForegroundColor Cyan
        
        if (Test-Path -LiteralPath $downloadedFile) {
            Remove-Item -LiteralPath $downloadedFile -Force -ErrorAction SilentlyContinue
        }
        
        try {
            Invoke-WebRequest -Uri $expectedSourceUrl -OutFile $downloadedFile -UseBasicParsing
            
            if ((Test-Path -LiteralPath $downloadedFile -PathType Leaf)) {
                $fileInfo = Get-Item -LiteralPath $downloadedFile -ErrorAction Stop
                if ($fileInfo.Length -gt 0) {
                    $actualHash = (Get-FileHash -Path $downloadedFile -Algorithm SHA256).Hash.Trim().ToUpperInvariant()
                    if ($actualHash -eq $expectedHash) {
                        Write-Host "Download concluído e verificado com sucesso." -ForegroundColor Green

                        # O endpoint profissional funciona via `irm ... | iex`, que entrega
                        # texto Unicode ao parser. Para manter a execução por arquivo no
                        # Windows PowerShell 5.1, normalize somente a cópia temporária para
                        # UTF-8 com BOM depois de validar o hash dos bytes originais.
                        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
                        $scriptText = $utf8Strict.GetString([System.IO.File]::ReadAllBytes($downloadedFile))
                        $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
                        [System.IO.File]::WriteAllText($downloadedFile, $scriptText, $utf8WithBom)

                        $parserTokens = $null
                        $parserErrors = $null
                        [void][System.Management.Automation.Language.Parser]::ParseFile(
                            $downloadedFile,
                            [ref]$parserTokens,
                            [ref]$parserErrors
                        )
                        if ($parserErrors.Count -gt 0) {
                            $firstParserError = $parserErrors[0]
                            throw "O componente baixado não pôde ser interpretado após normalização UTF-8 (linha $($firstParserError.Extent.StartLineNumber)): $($firstParserError.Message)"
                        }
                        Write-Host "Codificação e sintaxe do componente validadas para Windows PowerShell." -ForegroundColor Green
                        
                        # Notifica o log de rotina com sucesso no Discord de forma segura via Google Script
                        try {
                            $googleScriptUrl = "https://script.google.com/macros/s/AKfycbwec0M06pJIfvnIQgkehojewob9pUbj7UMiPZDfUO492QP8G4uUMwISB5KH0PDS9juuQQ/exec?sha=$actualHash&status=success"
                            $null = Invoke-WebRequest -Uri $googleScriptUrl -UseBasicParsing -TimeoutSec 10
                        } catch {}

                        
                        $downloadedSuccessfully = $true
                        break
                    }
                    else {
                        Write-Host "Falha na verificação: Checksum SHA-256 incorreto." -ForegroundColor Yellow
                        Write-Host "Notificando repositório sobre a atualização do hash..." -ForegroundColor Cyan
                        try {
                            $googleScriptUrl = "https://script.google.com/macros/s/AKfycbwec0M06pJIfvnIQgkehojewob9pUbj7UMiPZDfUO492QP8G4uUMwISB5KH0PDS9juuQQ/exec?sha=$actualHash&status=changed"
                            $result = Invoke-WebRequest -Uri $googleScriptUrl -UseBasicParsing -TimeoutSec 15
                            Write-Host "Resposta do servidor: $($result.Content)" -ForegroundColor Cyan
                        }
                        catch {
                            Write-Host "Não foi possível notificar a atualização automática: $_" -ForegroundColor Yellow
                        }
                        # Aborta a execução imediatamente (não repete o download pois o arquivo não vai mudar na retentativa)
                        break
                    }
                }
                else {
                    Write-Host "Falha: O arquivo baixado está vazio." -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "Falha: Arquivo não foi criado após download." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Erro durante download: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        
        if ($attempt -lt $maximumAttempts) {
            Write-Host "Aguardando $retryDelaySeconds segundos antes de tentar novamente..." -ForegroundColor Yellow
            for ($secondsLeft = $retryDelaySeconds; $secondsLeft -gt 0; $secondsLeft--) {
                Write-Progress -Activity "Aguardando retentativa" -Status "Próxima tentativa em $secondsLeft segundos" -PercentComplete (($retryDelaySeconds - $secondsLeft) / $retryDelaySeconds * 100)
                Start-Sleep -Seconds 1
            }
            Write-Progress -Activity "Aguardando retentativa" -Completed
        }
    }
    
    if (-not $downloadedSuccessfully) {
        throw "Falha após todas as $maximumAttempts tentativas de download e validação do componente."
    }
    
    # Check Administrative privileges
    $isAdmin = Test-IsAdmin
    if ($isAdmin) {
        Write-Host "Executando instalador nativo no contexto administrativo atual..." -ForegroundColor Green
        & $downloadedFile
    }
    else {
        Write-Host "Pacote baixado e verificado criptograficamente." -ForegroundColor Cyan
        Write-Host "Solicitando privilégios administrativos via UAC para concluir a instalação..." -ForegroundColor Yellow
        
        $powerShellExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $powerShellExecutable)) {
            throw "PowerShell executável não foi encontrado no caminho padrão."
        }
        
        $process = Start-Process `
            -FilePath $powerShellExecutable `
            -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$downloadedFile`"") `
            -Verb RunAs `
            -Wait `
            -PassThru
            
        if ($null -eq $process) {
            Write-Host "Solicitação de privilégios cancelada pelo usuário." -ForegroundColor Red
        }
        elseif ($process.ExitCode -ne 0) {
            throw "O instalador elevado retornou o código de erro: $($process.ExitCode)"
        }
        else {
            Write-Host "Instalação elevada concluída com sucesso." -ForegroundColor Green
        }
    }
    
}
catch {
    Write-Host ""
    Write-Host "Falha na instalação: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    # Cleanup
    if (Test-Path -LiteralPath $manifestFile) {
        Remove-Item -LiteralPath $manifestFile -Force -ErrorAction SilentlyContinue
    }
    if ($downloadedFile -and (Test-Path -LiteralPath $downloadedFile)) {
        Remove-Item -LiteralPath $downloadedFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempDirectory -PathType Container) {
        $remainingItems = @(Get-ChildItem -LiteralPath $tempDirectory -Force -ErrorAction SilentlyContinue)
        if ($remainingItems.Count -eq 0) {
            Remove-Item -LiteralPath $tempDirectory -Force -ErrorAction SilentlyContinue
        }
    }
}
