<#
.SYNOPSIS
    Pulizia approfondita dei metadati di un'immagine ISO 9660 / Joliet (con supporto El Torito).

.DESCRIPTION
    Neutralizza i campi identificativi contenuti nei Volume Descriptor (Primary e
    Supplementary/Joliet) di un file .iso e, opzionalmente, i timestamp interni:

        - System / Volume / Volume Set Identifier
        - Publisher / Data Preparer / Application Identifier
        - Copyright / Abstract / Bibliographic File Identifier
        - Date di creazione, modifica, scadenza ed efficacia del volume
        - Campo "Application Used" (512 byte liberi nel descrittore)
        - (opz.) timestamp di registrazione di OGNI Directory Record
        - (opz.) "ID string" nella Validation Entry del catalogo di boot El Torito
                 con ricalcolo del relativo checksum
        - (opz.) System Area (primi 32 KiB)

    Il file di partenza viene ripulito e SOSTITUITO: non resta nessuna copia
    rinominata. Di default la pulizia avviene su un file temporaneo nella stessa
    cartella, che al termine rimpiazza l'originale (piu' sicuro: se qualcosa va
    storto l'originale resta intatto). Con -InPlace la modifica e' scritta
    direttamente sul file, senza spazio disco aggiuntivo.
    Nessun campo ISO 9660 fra quelli toccati e' protetto da CRC, quindi
    l'immagine resta montabile.

    LIMITI: non tratta le strutture UDF (Logical Volume Identifier, timestamp e
    Developer ID nei File Entry, ecc.), che sono protette da tag/CRC. Se lo
    script segnala la presenza di UDF, per una pulizia completa rigenera
    l'immagine con xorriso.

.PARAMETER Path
    File .iso di origine.

.PARAMETER InPlace
    Scrive le modifiche direttamente sul file di -Path, senza file temporaneo.

.PARAMETER SkipDirectoryTimestamps
    Non azzerare i timestamp dei singoli Directory Record.

.PARAMETER SkipBootCatalog
    Non toccare il catalogo di boot El Torito.

.PARAMETER ZeroSystemArea
    Azzera i primi 32768 byte. Se contengono dati (es. MBR / boot ibrido) serve -Force.

.PARAMETER Force
    Consente l'azzeramento della System Area anche quando contiene dati.

.EXAMPLE
    .\Clean-IsoMetadata.ps1 -Path .\install.iso

.EXAMPLE
    .\Clean-IsoMetadata.ps1 -Path .\install.iso -InPlace -ZeroSystemArea -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$InPlace,
    [switch]$SkipDirectoryTimestamps,
    [switch]$SkipBootCatalog,
    [switch]$ZeroSystemArea,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SECTOR = 2048

# ---------------------------------------------------------------- helper I/O ---
function Read-Bytes {
    param([System.IO.Stream]$Stream, [long]$Offset, [int]$Count)
    $buf = New-Object byte[] $Count
    $Stream.Position = $Offset
    $done = 0
    while ($done -lt $Count) {
        $n = $Stream.Read($buf, $done, $Count - $done)
        if ($n -le 0) { break }
        $done += $n
    }
    if ($done -lt $Count) { $buf = $buf[0..([Math]::Max($done - 1, 0))] }
    return ,$buf
}

function Write-Bytes {
    param([System.IO.Stream]$Stream, [long]$Offset, [byte[]]$Data)
    $Stream.Position = $Offset
    $Stream.Write($Data, 0, $Data.Length)
}

# ------------------------------------------------------------- helper campi ---
function New-FillField {
    param([int]$Length, [bool]$Joliet)
    $b = New-Object byte[] $Length
    for ($i = 0; $i -lt $Length; $i++) {
        # spazio: 0x20 in ASCII, 0x0020 (BE) in UCS-2 per Joliet
        $b[$i] = if ($Joliet -and ($i % 2 -eq 0)) { 0x00 } else { 0x20 }
    }
    return ,$b
}

function New-BlankDateTime17 {
    # 16 cifre ASCII '0' + offset GMT 0  ==  "data non specificata"
    $b = New-Object byte[] 17
    for ($i = 0; $i -lt 16; $i++) { $b[$i] = 0x30 }
    return ,$b
}

function Get-VdString {
    param([System.IO.Stream]$Stream, [long]$Base, [int]$Off, [int]$Len, [bool]$Joliet)
    $raw = Read-Bytes $Stream ($Base + $Off) $Len
    $enc = if ($Joliet) { [System.Text.Encoding]::BigEndianUnicode } else { [System.Text.Encoding]::ASCII }
    return ($enc.GetString($raw)).Trim([char]0, ' ')
}

# ---------------------------------------------------- pulizia Volume Descriptor ---
function Clear-VolumeDescriptor {
    param([System.IO.Stream]$Stream, [long]$Base, [bool]$Joliet)

    $textFields = @(
        @{ Off = 8;   Len = 32  }   # System Identifier
        @{ Off = 40;  Len = 32  }   # Volume Identifier
        @{ Off = 190; Len = 128 }   # Volume Set Identifier
        @{ Off = 318; Len = 128 }   # Publisher Identifier
        @{ Off = 446; Len = 128 }   # Data Preparer Identifier
        @{ Off = 574; Len = 128 }   # Application Identifier
    )
    foreach ($f in $textFields) {
        Write-Bytes $Stream ($Base + $f.Off) (New-FillField $f.Len $Joliet)
    }
    foreach ($o in 702, 739, 776) {                       # File Identifier -> "nessuno"
        Write-Bytes $Stream ($Base + $o) (New-FillField 37 $false)
    }
    foreach ($o in 813, 830, 847, 864) {                  # date volume
        Write-Bytes $Stream ($Base + $o) (New-BlankDateTime17)
    }
    Write-Bytes $Stream ($Base + 883) (New-Object byte[] 512)   # Application Used

    $label = if ($Joliet) { 'Supplementary/Joliet' } else { 'Primary' }
    Write-Host ("  [+] Volume Descriptor {0} ripulito (settore {1})" -f $label, ($Base / $SECTOR))
}

# --------------------------------------------- azzeramento timestamp directory ---
function Clear-DirectoryTimestamps {
    param([System.IO.Stream]$Stream, [long]$VdBase)

    $rootRec = Read-Bytes $Stream ($VdBase + 156) 34
    $rootLba = [BitConverter]::ToUInt32($rootRec, 2)
    $rootLen = [BitConverter]::ToUInt32($rootRec, 10)
    if ($rootLba -eq 0 -or $rootLen -eq 0) { return 0 }

    $visited = New-Object 'System.Collections.Generic.HashSet[uint32]'
    $queue   = New-Object System.Collections.Queue
    [void]$queue.Enqueue(@{ Lba = $rootLba; Len = $rootLen })
    $count = 0

    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        if ($dir.Len -eq 0 -or $dir.Len -gt 64MB) { continue }
        if (-not $visited.Add([uint32]$dir.Lba)) { continue }

        $data = Read-Bytes $Stream ([long]$dir.Lba * $SECTOR) ([int]$dir.Len)
        $p = 0
        while ($p -lt $data.Length) {
            $recLen = $data[$p]
            if ($recLen -eq 0) {
                $next = ([Math]::Floor($p / $SECTOR) + 1) * $SECTOR
                if ($next -ge $data.Length) { break }
                $p = [int]$next
                continue
            }
            if ($p + $recLen -gt $data.Length -or $recLen -lt 34) { break }

            # timestamp registrazione: offset 18, 7 byte  ->  tutti zero
            Write-Bytes $Stream ([long]$dir.Lba * $SECTOR + $p + 18) (New-Object byte[] 7)
            $count++

            $flags   = $data[$p + 25]
            $nameLen = $data[$p + 32]
            $isDir   = ($flags -band 0x02) -ne 0
            $isDot   = ($nameLen -eq 1) -and ($data[$p + 33] -le 1)   # '.' (0x00) o '..' (0x01)
            if ($isDir -and -not $isDot) {
                [void]$queue.Enqueue(@{
                    Lba = [BitConverter]::ToUInt32($data, $p + 2)
                    Len = [BitConverter]::ToUInt32($data, $p + 10)
                })
            }
            $p += $recLen
        }
    }
    Write-Host ("  [+] Timestamp azzerati in {0} Directory Record (root LBA {1})" -f $count, $rootLba)
    return $count
}

# ------------------------------------------------------- El Torito boot catalog ---
function Clear-ElTorito {
    param([System.IO.Stream]$Stream, [long]$BrvdBase)

    Write-Bytes $Stream ($BrvdBase + 39) (New-Object byte[] 32)   # campo "unused" del BRVD

    $catLba = [BitConverter]::ToUInt32((Read-Bytes $Stream ($BrvdBase + 71) 4), 0)
    if ($catLba -eq 0) { return }

    $catOff = [long]$catLba * $SECTOR
    $val = Read-Bytes $Stream $catOff 32
    if ($val.Length -lt 32 -or $val[0] -ne 1 -or $val[30] -ne 0x55 -or $val[31] -ne 0xAA) {
        Write-Warning '  El Torito: Validation Entry non riconosciuta, salto.'
        return
    }

    for ($i = 4; $i -lt 28; $i++) { $val[$i] = 0 }        # ID string (24 byte)
    $val[28] = 0; $val[29] = 0                            # checksum -> ricalcolo
    $sum = 0
    for ($i = 0; $i -lt 32; $i += 2) { $sum += [BitConverter]::ToUInt16($val, $i) }
    $chk = [uint16]((0x10000 - ($sum -band 0xFFFF)) -band 0xFFFF)
    $val[28] = [byte]($chk -band 0xFF)
    $val[29] = [byte](($chk -shr 8) -band 0xFF)

    Write-Bytes $Stream $catOff $val
    Write-Host '  [+] El Torito: ID string azzerata e checksum ricalcolato'
}

# ------------------------------------------------------------------- report ---
function Show-PvdReport {
    param([System.IO.Stream]$Stream, [long]$Base, [string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    $map = [ordered]@{
        'System Identifier'        = @(8, 32)
        'Volume Identifier'        = @(40, 32)
        'Volume Set Identifier'    = @(190, 128)
        'Publisher Identifier'     = @(318, 128)
        'Data Preparer Identifier' = @(446, 128)
        'Application Identifier'   = @(574, 128)
    }
    foreach ($k in $map.Keys) {
        $v = Get-VdString $Stream $Base $map[$k][0] $map[$k][1] $false
        Write-Host ("  {0,-26}: {1}" -f $k, ($(if ($v) { "'$v'" } else { '<vuoto>' })))
    }
    foreach ($d in @{ 'Creazione' = 813; 'Modifica' = 830; 'Scadenza' = 847; 'Efficacia' = 864 }.GetEnumerator()) {
        $raw = [System.Text.Encoding]::ASCII.GetString((Read-Bytes $Stream ($Base + $d.Value) 16))
        Write-Host ("  Data {0,-21}: {1}" -f $d.Key, $raw)
    }
}

# =================================================================== main ===
$src = (Resolve-Path -LiteralPath $Path).Path
$size = (Get-Item -LiteralPath $src).Length
if ($size -lt ($SECTOR * 17)) { throw "File troppo piccolo per essere una ISO valida: $src" }
if ($size % $SECTOR -ne 0)   { Write-Warning "La dimensione non e' multipla di $SECTOR byte: immagine anomala o troncata." }

if ($InPlace) {
    $target = $src
    $tmp = $null
    Write-Warning "Modalita' -InPlace: il file viene modificato direttamente."
} else {
    # pulizia su file temporaneo nella stessa cartella, poi rimpiazza l'originale
    $tmp = Join-Path (Split-Path $src) ([System.IO.Path]::GetFileNameWithoutExtension($src) + '.cleaning-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Copy-Item -LiteralPath $src -Destination $tmp -Force
    $target = $tmp
    Write-Host "File di lavoro temporaneo: $target"
}

$fs = [System.IO.File]::Open($target, 'Open', 'ReadWrite', 'None')
try {
    # --- scansione UDF (solo avviso) ---
    for ($s = 16; $s -le 24; $s++) {
        $tag = [System.Text.Encoding]::ASCII.GetString((Read-Bytes $fs ([long]$s * $SECTOR + 1) 5))
        if ($tag -in 'NSR02', 'NSR03', 'BEA01') {
            Write-Warning "Rilevate strutture UDF (tag '$tag' al settore $s): NON vengono ripulite da questo script."
            break
        }
    }

    # --- report iniziale ---
    Show-PvdReport $fs ([long]16 * $SECTOR) '=== METADATI PRIMA ==='

    # --- ciclo Volume Descriptor ---
    $vdBases = New-Object System.Collections.ArrayList
    $lba = 16
    while ($true) {
        $base = [long]$lba * $SECTOR
        $hdr = Read-Bytes $fs $base 7
        if ($hdr.Length -lt 7) { break }
        if ([System.Text.Encoding]::ASCII.GetString($hdr, 1, 5) -ne 'CD001') {
            Write-Warning "Nessuna firma CD001 al settore ${lba}: fine scansione descrittori."
            break
        }
        $type = $hdr[0]
        if     ($type -eq 1) { Clear-VolumeDescriptor $fs $base $false; [void]$vdBases.Add(@{ Base = $base; Joliet = $false }) }
        elseif ($type -eq 2) { Clear-VolumeDescriptor $fs $base $true;  [void]$vdBases.Add(@{ Base = $base; Joliet = $true  }) }
        elseif ($type -eq 0) { if (-not $SkipBootCatalog) { Clear-ElTorito $fs $base } }
        elseif ($type -eq 255) { break }     # Volume Descriptor Set Terminator

        $lba++
        if ($lba -gt 1024) { Write-Warning 'Troppi descrittori: interruzione di sicurezza.'; break }
    }

    # --- timestamp dei Directory Record ---
    if (-not $SkipDirectoryTimestamps) {
        foreach ($vd in $vdBases) { [void](Clear-DirectoryTimestamps $fs $vd.Base) }
    }

    # --- System Area ---
    if ($ZeroSystemArea) {
        $sys = Read-Bytes $fs 0 32768
        $hasData = $false
        foreach ($b in $sys) { if ($b -ne 0) { $hasData = $true; break } }
        if ($hasData -and -not $Force) {
            Write-Warning 'System Area non vuota (possibile MBR / boot ibrido). Usa -Force per azzerarla comunque.'
        } else {
            Write-Bytes $fs 0 (New-Object byte[] 32768)
            Write-Host '  [+] System Area (32 KiB) azzerata'
        }
    }

    $fs.Flush()
    Show-PvdReport $fs ([long]16 * $SECTOR) '=== METADATI DOPO ==='
}
catch {
    $fs.Dispose()
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force }
    throw
}
$fs.Dispose()

if ($tmp) {
    # sostituisce l'originale con il file ripulito, conservando il nome
    Move-Item -LiteralPath $tmp -Destination $src -Force
}

Write-Host ""
Write-Host "Completato: $src" -ForegroundColor Green
