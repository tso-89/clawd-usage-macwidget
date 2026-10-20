# Exports upstream lib/i18n.ps1 string tables to Resources/strings.json.
param([string]$Upstream, [string]$Out)
. (Join-Path $Upstream 'lib/i18n.ps1')
$o = [ordered]@{}
foreach ($l in $Languages.Keys) {
    $t = [ordered]@{}
    foreach ($k in ($Strings[$l].Keys | Sort-Object)) { $t[$k] = $Strings[$l][$k] }
    $o[$l] = $t
}
$o | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM $Out
