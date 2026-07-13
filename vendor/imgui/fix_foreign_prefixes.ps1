param (
    [string]$FilePath
)

if (-not $FilePath -or -not (Test-Path $FilePath)) {
    Write-Error "Usage: fix_foreign_prefixes.ps1 <path-to-imgui.odin>"
    exit 1
}

$content = Get-Content -LiteralPath $FilePath

# Original structure (0-indexed):
# [0..2036]: header (package, imports, types, enums, structs)
# [2037]:     @(default_calling_convention = "c", link_prefix = "ImGui_")
# [2038]:     foreign imguilib {
# [2039..4798]: function body
# [4799]:     }

$header = $content[0..2036]
$bodyAll = $content[2039..4798]

$ig = @()   # functions needing ImGui_ prefix (no underscore)
$im = @()   # functions needing Im prefix (has underscore)
$cur = ""
$buf = @()

foreach ($line in $bodyAll) {
    if ($line -match '^\t(\w[\w_]*) :: proc') {
        if ($buf.Count -gt 0) {
            $text = $buf -join "`n"
            if ($cur -match '_') { $im += $text } else { $ig += $text }
        }
        $cur = $matches[1]
        $buf = @($line)
    } else {
        $buf += $line
    }
}
if ($buf.Count -gt 0) {
    $text = $buf -join "`n"
    if ($cur -match '_') { $im += $text } else { $ig += $text }
}

$out = @()
$out += $header
$out += ""
$out += '@(default_calling_convention = "c", link_prefix = "ImGui_")'
$out += "foreign imguilib {"
$out += ($ig -join "`n")
$out += "}"
$out += ""
$out += '@(default_calling_convention = "c", link_prefix = "Im")'
$out += "foreign imguilib {"
$out += ($im -join "`n")
$out += "}"

$out -join "`n" | Out-File -LiteralPath $FilePath -Encoding UTF8

Write-Host "Fixed $FilePath: $($ig.Count) ImGui_ prefix + $($im.Count) Im prefix functions"
