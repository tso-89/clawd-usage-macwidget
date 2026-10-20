# Exports upstream Clawd glyph tables and animation sequences to Resources/mascot.json.
param([string]$Upstream, [string]$Out)
$src = Get-Content (Join-Path $Upstream 'lib/mascot.ps1') -Raw
$cut = $src.IndexOf('# Burrow: dig')
Invoke-Expression $src.Substring(0, $cut)
$seqs = [ordered]@{}
foreach ($k in $ClawdSeqs.Keys) {
    $seqs[$k] = @($ClawdSeqs[$k] | ForEach-Object { [ordered]@{ eyes = $_.eyes; arms = $_.arms; feet = $_.feet; off = $_.off; x = $_.x; facing = $_.facing; poof = $_.poof; shadow = $_.shadow } })
}
$acts = [ordered]@{}
foreach ($k in $MascotActs.Keys) { $acts[$k] = [ordered]@{ len = $MascotActs[$k].len; noDemo = [bool]$MascotActs[$k].noDemo } }
$quad = [ordered]@{}; foreach ($k in $ClawdQuad.Keys) { $quad[[string]$k] = $ClawdQuad[$k] }
$facing = [ordered]@{}; foreach ($k in $ClawdFacing.Keys) { $facing[$k] = @($ClawdFacing[$k] | ForEach-Object { ,@($_[0], $_[1], $_[2]) }) }
[ordered]@{ quad = $quad; arms = $ClawdArms; feet = $ClawdFeet; facing = $facing; eyes = $EyeShapes
            seqs = $seqs; acts = $acts; clickActs = $ClawdClickActs; entranceActs = $ClawdEntranceActs } |
    ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8NoBOM $Out
