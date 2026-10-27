# V1 — Répartition : 20 appels successifs à /info ; tous les serveurs apparaissent, écart max-min < 20 %.
# Usage : powershell -ExecutionPolicy Bypass -File validation_scenario_v1.ps1 [-NbAppels 20]
param([int]$NbAppels = 20)
# AUTONOME : la bibliothèque commune est intégrée ci-dessous (aucun autre fichier requis).
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$script:Racine = $PSScriptRoot                         # racine du dépôt = dossier du Vagrantfile
while (-not (Test-Path (Join-Path $script:Racine 'Vagrantfile'))) {
  $parent = Split-Path $script:Racine -Parent
  if (-not $parent -or $parent -eq $script:Racine) { Write-Host "ERREUR : Vagrantfile introuvable au-dessus de $PSScriptRoot" -ForegroundColor Red; exit 1 }
  $script:Racine = $parent
}
Set-Location $script:Racine

function Import-DotEnv([string]$Fichier) {
  if (-not (Test-Path $Fichier)) { return }
  foreach ($l in (Get-Content $Fichier)) {
    $l = $l.TrimEnd("`r").Trim()
    if ($l -eq '' -or $l.StartsWith('#') -or $l.IndexOf('=') -lt 1) { continue }
    $k = $l.Substring(0, $l.IndexOf('=')).Trim(); $v = $l.Substring($l.IndexOf('=') + 1).Trim().Trim('"').Trim("'")
    if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
    if (-not [Environment]::GetEnvironmentVariable($k)) { [Environment]::SetEnvironmentVariable($k, $v, 'Process') }
  }
}
Import-DotEnv (Join-Path $script:Racine '.env'); Import-DotEnv (Join-Path $script:Racine 'app\api\.env')
function Get-Env([string]$Nom, [string]$Defaut) { $v = [Environment]::GetEnvironmentVariable($Nom); if ($v) { $v } else { $Defaut } }
$script:Groupe = [int](Get-Env 'GROUPE' '1'); $script:NbApp = [int](Get-Env 'NB_APP' '2')
$env:GROUPE = "$script:Groupe"; $env:NB_APP = "$script:NbApp"      # les commandes vagrant en ont besoin
$script:PgPort = Get-Env 'PG_PORT' '5432'; $script:PgDb = Get-Env 'PG_DB' 'postgres'
$script:Reseau = "192.168.$(55 + $script:Groupe)"
$script:LbUrl = Get-Env 'LB_URL' 'http://127.0.0.1:8080'

# ---------- Source de vérité : config\noeuds.yml ----------
function Get-Noeuds {
  $f = Join-Path $script:Racine 'config\noeuds.yml'; $res = @()
  if (-not (Test-Path $f)) { return $res }
  $nom = $null; $ip = $null
  foreach ($l in (Get-Content $f)) {
    $l = $l.TrimEnd("`r")
    if ($l -match '^- :nom:\s*(\S+)') { $nom = $Matches[1] }
    elseif ($l -match '^\s+:ip:\s*(\S+)') { $ip = $Matches[1] }
    elseif ($l -match '^\s+:role:\s*(\S+)') { $res += [pscustomobject]@{ Nom = $nom; Ip = $ip; Role = $Matches[1] } }
  }
  return $res
}
function Get-NoeudIp([string]$Nom) { foreach ($n in @(Get-Noeuds)) { if ($n.Nom -eq $Nom) { return $n.Ip } }; return '' }
function Get-Apps { @(Get-Noeuds | Where-Object { $_.Role -eq 'app' } | ForEach-Object { $_.Nom }) }
$script:IpLb1 = Get-NoeudIp 'lb1'; if (-not $script:IpLb1) { $script:IpLb1 = "$($script:Reseau).11" }
$script:Vip = ''                                                     # même source que lb1.sh/lb2.sh : config\vip.env, sinon <réseau>.5
$fvip = Join-Path $script:Racine 'config\vip.env'
if (Test-Path $fvip) { foreach ($l in (Get-Content $fvip)) { if ($l.TrimEnd("`r") -match '^VIP=(\S+)') { $script:Vip = $Matches[1].Trim('"', "'") } } }
if (-not $script:Vip) { $script:Vip = ($script:IpLb1 -replace '\.\d+$', '.5') }
$script:VipUrl = Get-Env 'VIP_URL' "http://$($script:Vip)"

# ---------- Affichage + journal + rapport ----------
$script:Journal = New-Object System.Collections.Generic.List[string]
$script:Mesures = New-Object System.Collections.Generic.List[string]
$script:Verdicts = New-Object System.Collections.Generic.List[string]
$script:RapOk = $true; $script:RapId = ''; $script:RapTitre = ''; $script:RapCmd = ''
function Say([string]$T)    { Write-Host $T; $script:Journal.Add($T) }
function Etape([string]$T)  { Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan; $script:Journal.Add(''); $script:Journal.Add("== $T ==") }
function Ok([string]$T)     { Write-Host "  [OK] $T" -ForegroundColor Green; $script:Journal.Add("  [OK] $T") }
function Ko([string]$T)     { Write-Host "  [ECHEC] $T" -ForegroundColor Red; $script:Journal.Add("  [ECHEC] $T") }
function Warn([string]$T)   { Write-Host "  [!] $T" -ForegroundColor Yellow; $script:Journal.Add("  [ATTENTION] $T") }
function Cmd([string]$T)    { Write-Host "  > $T"; $script:Journal.Add("  > $T") }
function Bloc([string]$Titre, [string]$Texte) {
  $lignes = ($Texte -split "`n") | ForEach-Object { "    $_" }
  $lignes | ForEach-Object { Write-Host $_ }; $script:Journal.Add("  -- $Titre --"); $lignes | ForEach-Object { $script:Journal.Add($_) }
}
function Mesure([string]$L, [string]$V) { Write-Host ("  * {0,-48} {1}" -f $L, $V); $script:Mesures.Add("| $L | $V |") }
function Verdict([bool]$Reussi, [string]$T) {
  if ($Reussi) { Ok $T; $script:Verdicts.Add("- [OK] $T") } else { Ko $T; $script:Verdicts.Add("- [ECHEC] $T"); $script:RapOk = $false }
}
function Stop-Script([string]$T) { Write-Host "ERREUR : $T" -ForegroundColor Red; exit 1 }
function Rapport-Debut([string]$Id, [string]$Titre, [string]$Commande) {
  $script:RapId = $Id; $script:RapTitre = $Titre; $script:RapCmd = $Commande; Write-Host ''; Write-Host "$Id - $Titre" -ForegroundColor White
}
function Rapport-Fin {
  $dossier = Join-Path $script:Racine 'mesures'; if (-not (Test-Path $dossier)) { New-Item -ItemType Directory -Path $dossier | Out-Null }
  $f = Join-Path $dossier ("{0}_{1}.md" -f $script:RapId, (Get-Date -Format 'yyyyMMdd_HHmmss'))
  $vg = (& vagrant --version 2>$null | Select-Object -First 1)
  $t = @()
  $t += "# $($script:RapId) — $($script:RapTitre)"; $t += ''
  $t += "- Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $t += "- Poste : $([Environment]::OSVersion.VersionString) | PowerShell $($PSVersionTable.PSVersion) | $vg"
  $t += "- Groupe $($script:Groupe) ($($script:Reseau).0/24) | NB_APP=$($script:NbApp) | Répartiteur $($script:LbUrl)"; $t += ''
  $t += '## Commande exacte'; $t += ''; $t += '```'; $t += $script:RapCmd; $t += '```'; $t += ''
  $t += '## Résultat brut'; $t += ''; $t += '```'; $t += $script:Journal; $t += '```'; $t += ''
  $t += '## Mesures'; $t += ''; $t += '| Mesure | Valeur |'; $t += '|---|---|'; $t += $script:Mesures; $t += ''
  $t += '## Verdict'; $t += ''; $t += $script:Verdicts; $t += ''
  $t += '## Commentaire'; $t += ''; $t += "_À rédiger : interprétation honnête des chiffres, limites (les VM se partagent un seul processeur)._"
  [IO.File]::WriteAllText($f, ($t -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ''; Write-Host "Rapport : $f" -ForegroundColor White
  if ($script:RapOk) { exit 0 } else { exit 1 }
}

# ---------- Vagrant / HTTP ----------
function Invoke-Vm([string]$Vm, [string]$Commande) {
  # Pas de guillemets doubles dans $Commande : Windows PowerShell 5.1 les perd en les passant à un exécutable.
  $out = $null | & vagrant ssh $Vm -c $Commande 2>$null
  return ((@($out) -join "`n") -replace "`r", '').Trim()
}
function Get-VmState([string]$Vm) {
  foreach ($l in @(& vagrant status $Vm --machine-readable 2>$null)) { $p = "$l".Split(','); if ($p.Count -ge 4 -and $p[2] -eq 'state') { return $p[3] } }
  return ''
}
function Invoke-Vagrant([string[]]$VArgs, [string]$NbApp = '') {
  $old = $env:NB_APP; if ($NbApp) { $env:NB_APP = $NbApp }
  try { $out = & vagrant @VArgs 2>&1; $script:VagrantExit = $LASTEXITCODE; return $out } finally { $env:NB_APP = $old }
}
function Get-Http([string]$Url, [int]$TimeoutS = 3) {
  $r = [pscustomobject]@{ Code = 0; Body = ''; Ms = 0 }; $resp = $null
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = $TimeoutS * 1000; $req.ReadWriteTimeout = $TimeoutS * 1000; $req.KeepAlive = $false; $req.Proxy = $null
    $resp = $req.GetResponse()
  } catch [System.Net.WebException] { $resp = $_.Exception.Response } catch { $resp = $null }
  if ($resp) {
    try { $r.Code = [int]$resp.StatusCode; $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $r.Body = $sr.ReadToEnd(); $sr.Close() } catch { } finally { $resp.Close() }
  }
  $r.Ms = $sw.ElapsedMilliseconds
  return $r
}
function Get-ServerName([string]$Body) {
  if ($Body -match 'app\d+') { return $Matches[0] }
  $t = ($Body -replace '[\r\n"{} ]', ''); if ($t.Length -gt 40) { $t = $t.Substring(0, 40) }; return $t
}
function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Count-Distincts([string]$Url, [int]$N) {
  $set = @{}; for ($i = 0; $i -lt $N; $i++) { $r = Get-Http $Url 2; if ($r.Code -ge 200 -and $r.Code -lt 300) { $set[(Get-ServerName $r.Body)] = 1 } }; return $set.Count
}
function Wait-Serveurs([int]$N, [int]$TimeoutS = 120) {
  for ($i = 0; $i -lt $TimeoutS; $i++) { if ((Count-Distincts "$($script:LbUrl)/info" ($N * 4)) -ge $N) { return $true }; Start-Sleep -Seconds 1 }
  return $false
}
function Get-Matricule {
  $m = Get-Env 'MATRICULE' ''
  if (-not $m) {
    $q = "sudo -u postgres psql -p $($script:PgPort) -d $($script:PgDb) -tAc 'SELECT matricule_candidat FROM resultat ORDER BY 1 LIMIT 1'"
    $m = ((Invoke-Vm 'bdd1' $q) -split "`n" | Select-Object -First 1).Trim()
  }
  return $m
}

# ---------- Sondes en arrière-plan (RunspacePool : fonctionne en PowerShell 5.1 et 7) ----------
function Start-Sondes([string]$Url, [int]$Workers = 1, [double]$PauseS = 0.1, [int]$TimeoutS = 2) {
  $state = [hashtable]::Synchronized(@{ Stop = $false })
  $bag = New-Object 'System.Collections.Concurrent.ConcurrentBag[string]'
  $fnHttp = ${function:Get-Http}.ToString(); $fnSrv = ${function:Get-ServerName}.ToString()
  $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $Workers)); $pool.Open()
  $worker = {
    param($Url, $PauseS, $TimeoutS, $state, $bag, $fnHttp, $fnSrv)
    Invoke-Expression "function Get-Http { $fnHttp }"; Invoke-Expression "function Get-ServerName { $fnSrv }"
    while (-not $state.Stop) {
      $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); $r = Get-Http $Url $TimeoutS
      $h = Get-ServerName $r.Body; if (-not $h) { $h = '-' }
      $bag.Add("$t $($r.Code) $h"); Start-Sleep -Milliseconds ([int]($PauseS * 1000))
    }
  }
  $handles = @()
  for ($i = 0; $i -lt $Workers; $i++) {
    $ps = [powershell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument($Url).AddArgument($PauseS).AddArgument($TimeoutS).AddArgument($state).AddArgument($bag).AddArgument($fnHttp).AddArgument($fnSrv)
    $handles += [pscustomobject]@{ Ps = $ps; Async = $ps.BeginInvoke() }
  }
  return [pscustomobject]@{ State = $state; Bag = $bag; Pool = $pool; Handles = $handles }
}
function Stop-Sondes($S) {
  $S.State.Stop = $true
  foreach ($h in $S.Handles) { try { [void]$h.Ps.EndInvoke($h.Async) } catch { }; $h.Ps.Dispose() }
  $S.Pool.Close()
  $entrees = foreach ($l in $S.Bag.ToArray()) { $p = $l.Split(' '); [pscustomobject]@{ T = [long]$p[0]; Code = [int]$p[1]; Srv = $p[2] } }
  return @($entrees | Sort-Object T)
}

# Analyse d'un journal de sondes, T0 = instant de la panne (ms). Mêmes définitions que lib.sh :
#  FirstS/LastS : première/dernière erreur après T0 ; GapS : plus longue période SANS aucune réponse 2xx ;
#  Late : erreurs plus de 5 s après T0 ; Open : le service n'est pas revenu à la fin.
function Get-Analyse($Entrees, [long]$T0) {
  $ok = 0; $err = 0; $late = 0; $gap = 0; $first = $null; $last = $null; $inerr = $false; $lastOk = $null; $codes = @{}
  foreach ($e in @($Entrees)) {
    if ($e.Code -ge 200 -and $e.Code -lt 300) {
      $ok++
      if ($inerr -and $null -ne $lastOk) { $g = $e.T - $lastOk; if ($g -gt $gap) { $gap = $g } }
      $inerr = $false; $lastOk = $e.T
    } else {
      $err++; if ($null -eq $first) { $first = $e.T }; $last = $e.T; if (($e.T - $T0) -gt 5000) { $late++ }
      $k = "$($e.Code)"; if ($codes.ContainsKey($k)) { $codes[$k]++ } else { $codes[$k] = 1 }; $inerr = $true
    }
  }
  $open = 0; if ($inerr -and $null -ne $lastOk) { $g = $last - $lastOk; if ($g -gt $gap) { $gap = $g }; $open = 1 }
  $cs = (($codes.Keys | Sort-Object | ForEach-Object { "$_ x$($codes[$_])" }) -join '  ')
  $f = '-'; $l = '-'; if ($null -ne $first) { $f = '{0:N2}' -f (($first - $T0) / 1000.0) }; if ($null -ne $last) { $l = '{0:N2}' -f (($last - $T0) / 1000.0) }
  return [pscustomobject]@{ Total = @($Entrees).Count; Ok = $ok; Err = $err; FirstS = $f; LastS = $l; GapS = [math]::Round($gap / 1000.0, 2); Late = $late; Open = $open; Codes = $cs }
}
function Get-RepartitionTexte($Entrees, [string]$Champ) {
  (@($Entrees) | Group-Object $Champ | Sort-Object Name | ForEach-Object { "{0,6} {1}" -f $_.Count, $_.Name }) -join "`n"
}

# ===================== Scénario =====================
Rapport-Debut 'V1' "Répartition — $NbAppels appels successifs à /info" "powershell -ExecutionPolicy Bypass -File validation_scenario_v1.ps1 -NbAppels $NbAppels"
$attendus = @(Get-Apps); if ($attendus.Count -eq 0) { Stop-Script "Aucun serveur applicatif dans config\noeuds.yml (vagrant up d'abord)" }

Etape 'Appels successifs'
Cmd "1..$NbAppels | % { Invoke-WebRequest $($script:LbUrl)/info }"
$obs = @(); $erreurs = 0
for ($i = 1; $i -le $NbAppels; $i++) {
  $r = Get-Http "$($script:LbUrl)/info" 3
  if ($r.Code -ge 200 -and $r.Code -lt 300) { $s = Get-ServerName $r.Body; $obs += $s; Say ("  appel {0,2} : HTTP {1}  {2}" -f $i, $r.Code, $s) }
  else { $erreurs++; Say ("  appel {0,2} : HTTP {1}  (ERREUR)" -f $i, $r.Code) }
}
$groupes = @($obs | Group-Object | Sort-Object Name)
Bloc 'Répartition' ((@($groupes | ForEach-Object { "{0,6} {1}" -f $_.Count, $_.Name })) -join "`n")

Etape 'Mesures'
$vus = $groupes.Count
$max = 0; $min = 0
if ($vus -gt 0) { $max = ($groupes | Measure-Object Count -Maximum).Maximum; $min = ($groupes | Measure-Object Count -Minimum).Minimum }
if ($vus -lt $attendus.Count) { $min = 0 }      # un serveur jamais sollicité compte pour 0
$ecart = [math]::Round(($max - $min) / [double]$NbAppels * 100, 1)
Mesure 'Serveurs attendus / observés' "$($attendus.Count) / $vus"
Mesure 'Requêtes réussies / en erreur' "$($obs.Count) / $erreurs"
Mesure 'Plus sollicité / moins sollicité' "$max / $min"
Mesure 'Écart (max−min) / total' "$ecart %"
Verdict ($vus -ge $attendus.Count) $(if ($vus -ge $attendus.Count) { "Les $($attendus.Count) serveurs apparaissent" } else { "Serveur(s) absent(s) : $vus/$($attendus.Count) (HAProxy ? VM arrêtée ?)" })
Verdict ($ecart -lt 20) "Écart $ecart % (seuil : < 20 %)"
Verdict ($erreurs -eq 0) $(if ($erreurs -eq 0) { 'Aucune erreur' } else { "$erreurs erreur(s)" })
Rapport-Fin
