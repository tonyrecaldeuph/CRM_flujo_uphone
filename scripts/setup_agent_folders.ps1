# setup_agent_folders.ps1
# Asegura la estructura de carpetas para el sistema multi-agente

$ProjectRoot = Get-Location
$AgentesDir = Join-Path $ProjectRoot ".agentes"
$SubDirs = @("handoffs", "validaciones", "incidencias", "archivo")

Write-Host "Configurando infraestructura de agentes en: $AgentesDir" -ForegroundColor Cyan

# Crear carpetas si no existen
foreach ($dirName in $SubDirs) {
    $path = Join-Path $AgentesDir $dirName
    if (!(Test-Path $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
        Write-Host "[NUEVO] Carpeta creada: $dirName" -ForegroundColor Green
    } else {
        Write-Host "[OK] Carpeta existente: $dirName" -ForegroundColor DarkGray
    }
}

# Verificar estado_proyecto.md
$EstadoFile = Join-Path $AgentesDir "estado_proyecto.md"
if (!(Test-Path $EstadoFile)) {
    Write-Host "[ADVERTENCIA] No se encontró estado_proyecto.md" -ForegroundColor Yellow
} else {
    Write-Host "[OK] Archivo de estado detectado." -ForegroundColor DarkGray
}

Write-Host "`nEstructura de orquestación verificada exitosamente." -ForegroundColor Cyan

# Alertas de uso sugerido (Aliases para PowerShell)
Write-Host "`nSugerencia: Agrega estos aliases a tu `$PROFILE para mayor rapidez:" -ForegroundColor Yellow
Write-Host "function tareas { Get-ChildItem .agentes/handoffs | Sort-Object LastWriteTime -Descending }"
Write-Host "function bugs { Get-ChildItem .agentes/incidencias | Sort-Object LastWriteTime -Descending }"
Write-Host "function estado { Get-Content .agentes/estado_proyecto.md }"
