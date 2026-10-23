# Checks Marktplaats for new van listings and pushes them to ntfy.
# Env: NTFY_TOPIC (required unless -DryRun). State is kept in seen.json next to this script.
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$searches = @(
    @{ Name = 'VW LT 28/35';      Query = 'volkswagen lt'; From = 2000; To = 2006; Match = '\blt\s*-?\s*(28|35)' }
    @{ Name = 'VW LT 28/35';      Query = 'lt28';          From = 2000; To = 2006; Match = '\blt\s*-?\s*(28|35)' }
    @{ Name = 'VW LT 28/35';      Query = 'lt35';          From = 2000; To = 2006; Match = '\blt\s*-?\s*(28|35)' }
    @{ Name = 'Sprinter 210-312'; Query = 'sprinter';      From = 1997; To = 1999; Match = '\b(210|212|214|308|310|312)\s*d?\b' }
)

$statePath = Join-Path $PSScriptRoot 'seen.json'
$seen = @{}
if (Test-Path $statePath) {
    foreach ($id in (Get-Content $statePath -Raw | ConvertFrom-Json)) { $seen[$id] = $true }
}
$firstRun = $seen.Count -eq 0

$headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; 'Accept' = 'application/json' }
$found = [ordered]@{}

# Campers and some vans have no constructionYear attribute, so the year-filtered search misses them.
# Second pass without the year filter: vehicle listings only, year taken from the text (or unknown).
$vehiclePath = '^/v/(auto-s|caravans-en-kamperen/campers)/'

foreach ($s in $searches) {
  foreach ($yearFilter in $true, $false) {
    $url = 'https://www.marktplaats.nl/lrp/api/search?query=' + [uri]::EscapeDataString($s.Query) +
           '&limit=100&offset=0&sortBy=SORT_INDEX&sortOrder=DECREASING'
    if ($yearFilter) { $url += '&attributeRanges%5B%5D=constructionYear%3A' + $s.From + '%3A' + $s.To }
    $res = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 30
    foreach ($l in $res.listings) {
        if (-not $l.itemId -or -not $l.vipUrl) { continue }
        $text = "$($l.title) $($l.categorySpecificDescription) $($l.description)"
        $year = ($l.attributes | Where-Object key -eq 'constructionYear' | Select-Object -First 1).value
        if (-not $year) {
            if ($l.vipUrl -notmatch $vehiclePath) { continue }
            $year = if ($text -match '\b(19[5-9]\d|20[0-2]\d)\b') { $Matches[1] } else { '?' }
        }
        if ($year -ne '?' -and ([int]$year -lt $s.From -or [int]$year -gt $s.To)) { continue }
        if ($text -notmatch $s.Match) { continue }
        if ($found.Contains($l.itemId)) { continue }

        $price = switch ($l.priceInfo.priceType) {
            'FIXED'     { 'EUR {0:N0}' -f ($l.priceInfo.priceCents / 100) }
            'MIN_BID'   { 'Bieden vanaf EUR {0:N0}' -f ($l.priceInfo.priceCents / 100) }
            'FAST_BID'  { 'Bieden' }
            'SEE_DESCRIPTION' { 'Zie omschrijving' }
            'NOTK'      { 'N.o.t.k.' }
            default     { if ($l.priceInfo.priceCents) { 'EUR {0:N0}' -f ($l.priceInfo.priceCents / 100) } else { "$($l.priceInfo.priceType)" } }
        }
        $found[$l.itemId] = [pscustomobject]@{
            Id = $l.itemId; Search = $s.Name; Title = $l.title; Year = $year; Price = $price
            City = $l.location.cityName; Url = 'https://www.marktplaats.nl' + $l.vipUrl
            Image = if ($l.pictures) { $l.pictures[0].largeUrl } else { $null }
        }
    }
  }
}

$new = @($found.Values | Where-Object { -not $seen.ContainsKey($_.Id) })
Write-Host "Matches: $($found.Count), new: $($new.Count)"

foreach ($n in $new) {
    Write-Host " - [$($n.Search)] $($n.Year) $($n.Title) | $($n.Price) | $($n.City) | $($n.Url)"
    if ($DryRun) { continue }
    $msg = @{
        topic    = $env:NTFY_TOPIC
        title    = "$($n.Search): $($n.Year) - $($n.Price)"
        message  = "$($n.Title)`n$($n.City)"
        click    = $n.Url
        tags     = @('truck')
        priority = 4
    }
    if ($n.Image) { $msg.attach = $n.Image }
    $body = [Text.Encoding]::UTF8.GetBytes(($msg | ConvertTo-Json -Compress))
    Invoke-RestMethod -Method Post -Uri 'https://ntfy.sh/' -Body $body -ContentType 'application/json; charset=utf-8' | Out-Null
    $seen[$n.Id] = $true
}

if (-not $DryRun -and $firstRun) {
    $body = [Text.Encoding]::UTF8.GetBytes((@{ topic = $env:NTFY_TOPIC; title = 'Marktplaats bot is live'
        message = "Sent $($new.Count) current listings. From now on you only get new ones." } | ConvertTo-Json -Compress))
    Invoke-RestMethod -Method Post -Uri 'https://ntfy.sh/' -Body $body -ContentType 'application/json; charset=utf-8' | Out-Null
}

if (-not $DryRun) {
    ConvertTo-Json -InputObject @($seen.Keys | Sort-Object) | Set-Content $statePath -Encoding utf8
}
