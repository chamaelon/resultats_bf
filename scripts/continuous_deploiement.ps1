# =============================================================================
#  continuous_deploiement.ps1 — Déploiement continu SANS COUPURE (rolling update)   [Windows 11 : PowerShell 5.1 ou 7]
#  À LANCER SUR L'HÔTE (n'importe où dans le dépôt) :
#     powershell -ExecutionPolicy Bypass -File continuous_deploiement.ps1 [options]
#  (Linux / macOS / WSL / Git Bash : continuous_deploiement.sh, mêmes options, même comportement)
#
#  Pour CHAQUE serveur applicatif qui doit changer, un par un :
#    1. vérifie que tous les autres sont UP dans HAProxy (jamais deux hors service) ;
#    2. le met en DRAIN dans HAProxy et attend la fin de ses sessions en cours ;
#    3. sauvegarde la version en place (/opt/app.prev), installe la nouvelle et redémarre api-app ;
#    4. attend /sante = 200 ; sinon RETOUR ARRIÈRE automatique et arrêt du déploiement ;
#    5. le remet en service (READY) et attend que HAProxy le voie UP ; 6. passe au suivant.
#
#  IDEMPOTENCE — mêmes paramètres => même état final, sans effet de bord :
#    - La version = empreinte SHA-256 de dist/index.js. Un serveur déjà à cette version est SAUTÉ
#      (ni drain ni redémarrage) ; si tous le sont : « rien à faire », code 0.
#    - /opt/app.prev garde la dernière version DIFFÉRENTE : rejouer un déploiement ne détruit plus
#      le retour arrière.
#    - -Rollback ne permute pas : un serveur déjà sur la version précédente est sauté ; rejoué, il
#      converge. Pour ré-avancer : relancer le déploiement.   -Force réinstalle même si identique.
#
#  Serveurs lus dans config\noeuds.yml (aucun en dur). AUTONOME : la logique exécutée dans les VM est
#  EMBARQUÉE dans ce fichier (variable $RemoteScript, identique à celle de continuous_deploiement.sh).
#  Drain / remise en service appliqués sur TOUS les répartiteurs en ligne (lb1 et lb2).
#
#  Options :
#    -Charge [-ChargeWorkers 20]  génère de la charge pendant le déploiement et compte les erreurs (démo E4)
#    -NoBuild | -Build            ne pas compiler / forcer la compilation
#    -Only app2,app3              ne traite que ces serveurs  (écrire -Only 'app2,app3' si appelé via -File)
#    -Rollback                    revient à la version précédente, serveur par serveur
#    -Status                      affiche versions et état HAProxy, sans rien changer
#    -DryRun                      affiche le plan sans rien exécuter
#    -Force                       réinstalle même si le serveur est déjà à la bonne version
#    -AllowSingle                 autorise le déploiement avec un seul serveur en ligne (COUPURE !)
#  Variables d'environnement : LB_VMS (défaut 'lb1 lb2') LB_URL PROBE_PATH ACCEPT CHARGE_DELAY SANTE_TIMEOUT DRAIN_TIMEOUT
#    UP_TIMEOUT HAPROXY_SOCK BUILD_CMD
#  Codes de sortie : 0 succès (ou rien à faire) | 1 erreur avant déploiement | 2 nouvelle version refusée
#    (retour arrière effectué) | 3 serveur cassé | 4 requêtes en erreur pendant la charge.
# =============================================================================
param(
  [switch]$Charge, [int]$ChargeWorkers = 20, [switch]$NoBuild, [switch]$Build, [string]$Only = '',
  [switch]$Rollback, [switch]$Status, [switch]$DryRun, [switch]$Force, [switch]$AllowSingle
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$Racine = $PSScriptRoot                                   # racine du dépôt = dossier du Vagrantfile
while (-not (Test-Path (Join-Path $Racine 'Vagrantfile'))) {
  $parent = Split-Path $Racine -Parent
  if (-not $parent -or $parent -eq $Racine) { Write-Host "ERREUR : Vagrantfile introuvable au-dessus de $PSScriptRoot" -ForegroundColor Red; exit 1 }
  $Racine = $parent
}
Set-Location $Racine

function Env([string]$n, [string]$d) { $v = [Environment]::GetEnvironmentVariable($n); if ($v) { $v } else { $d } }
$LbVms = @((Env 'LB_VMS' (Env 'LB_VM' 'lb1 lb2')) -split '[,; ]+' | Where-Object { $_ }); $LbUrl = Env 'LB_URL' 'http://127.0.0.1:8080'; $ProbePath = Env 'PROBE_PATH' '/info'
$Accept = Env 'ACCEPT' '^2'; $ChargeDelay = [double](Env 'CHARGE_DELAY' '0.05')
$SanteTimeout = [int](Env 'SANTE_TIMEOUT' '60'); $DrainTimeout = [int](Env 'DRAIN_TIMEOUT' '20'); $UpTimeout = [int](Env 'UP_TIMEOUT' '40')
$HapSock = Env 'HAPROXY_SOCK' '/run/haproxy/admin.sock'
$FichierNoeuds = Join-Path $Racine 'config\noeuds.yml'
$RemoteRel = 'config/.cd-remote.sh'; $RemoteLocal = Join-Path $Racine 'config\.cd-remote.sh'
$Action = if ($Rollback) { 'rollback' } elseif ($Status) { 'status' } else { 'deploy' }
$ForceN = if ($Force) { 1 } else { 0 }

# ---------- Affichage ----------
function Titre([string]$t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Info([string]$t)  { Write-Host "   $t" }
function Ok([string]$t)    { Write-Host "   [OK] $t" -ForegroundColor Green }
function Warn([string]$t)  { Write-Host "   [!] $t" -ForegroundColor Yellow }
function Die([string]$t, [int]$code = 1) { throw "CDDIE|$code|$t" }

$script:ChargeCtx = $null; $script:Drained = New-Object System.Collections.ArrayList; $script:HapOk = $false; $script:HapVms = @()

# ---------- Accès aux VM ----------
function Vm([string]$vm, [string]$cmd) {
  # Pas de guillemets doubles dans $cmd : Windows PowerShell 5.1 les perd en les passant à un exécutable.
  $out = $null | & vagrant ssh $vm -c $cmd 2>$null
  return ((@($out) -join "`n") -replace "`r", '')
}
function Etat-Vm([string]$vm) {
  foreach ($l in @(& vagrant status $vm --machine-readable 2>$null)) { $p = "$l".Split(','); if ($p.Count -ge 4 -and $p[2] -eq 'state') { return $p[3] } }
  return ''
}
function Remote([string]$vm, [string]$action) { return Vm $vm "sudo bash /vagrant/$RemoteRel $action $SanteTimeout $ForceN" }
function Champ([string]$sortie, [string]$cle) { $m = [regex]::Matches($sortie, "$cle=(\S+)"); if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups[1].Value }; return '' }

# ---------- HAProxy (socket d'administration, sur CHAQUE répartiteur en ligne) ----------
function Hap-Sur([string]$vm, [string]$c) { return Vm $vm "echo '$c' | sudo socat stdio $HapSock" }
function Hap([string]$c) { foreach ($l in @($script:HapVms)) { [void](Hap-Sur $l $c) } }     # commande sur TOUS les répartiteurs
function Hap-Champ([string]$vm, [string]$srv, [int]$idx) {
  $p = $srv.Split('/'); foreach ($l in ((Hap-Sur $vm 'show stat') -split "`n")) { $f = $l.Split(','); if ($f.Count -gt $idx -and $f[0] -eq $p[0] -and $f[1] -eq $p[1]) { return $f[$idx] } }; return ''
}
function Hap-Sessions([string]$srv) {   # somme des sessions en cours sur tous les répartiteurs
  $tot = 0; foreach ($l in @($script:HapVms)) { $n = Hap-Champ $l $srv 4; if ("$n" -match '^\d+$') { $tot += [int]$n } }; return "$tot"
}
function Hap-Statut([string]$srv) {     # premier état non-UP rencontré ; sinon UP
  $res = ''
  foreach ($l in @($script:HapVms)) { $st = Hap-Champ $l $srv 17; if (-not $st) { continue }; if ($st -notlike 'UP*') { return $st }; if (-not $res) { $res = $st } }
  return $res
}
function Attendre-Drain([string]$srv) {
  $n = ''
  for ($i = 0; $i -lt $DrainTimeout; $i++) { $n = Hap-Sessions $srv; if ($n -eq '0') { return }; Start-Sleep -Seconds 1 }
  Warn "$srv : $n session(s) encore ouverte(s) après ${DrainTimeout}s (on continue)"
}
function Attendre-Up([string]$srv) {
  $st = ''
  for ($i = 0; $i -lt $UpTimeout; $i++) { $st = Hap-Statut $srv; if ($st -like 'UP*') { return $true }; Start-Sleep -Seconds 1 }
  Warn "$srv : état HAProxy '$st' après ${UpTimeout}s"; return $false
}
function Srv-Haproxy([string]$state, [string]$nom, [string]$ip) {
  foreach ($l in ($state -split "`n")) {
    $f = ($l.Trim() -split '\s+'); if ($f.Count -ge 6 -and $f[0] -match '^\d+$' -and ($f[4] -eq $ip -or $f[3] -eq $nom)) { return "$($f[1])/$($f[3])" }
  }
  return ''
}

# ---------- HTTP + charge (RunspacePool) ----------
function Get-HttpCode([string]$Url, [int]$TimeoutS = 3) {
  $resp = $null
  try { $req = [System.Net.HttpWebRequest]::Create($Url); $req.Timeout = $TimeoutS * 1000; $req.KeepAlive = $false; $req.Proxy = $null; $resp = $req.GetResponse() }
  catch [System.Net.WebException] { $resp = $_.Exception.Response } catch { $resp = $null }
  if ($resp) { $c = [int]$resp.StatusCode; $resp.Close(); return $c }; return 0
}
function Charge-Start {
  Titre "Charge pendant le déploiement : $ChargeWorkers travailleurs sur $LbUrl$ProbePath"
  $c = Get-HttpCode "$LbUrl$ProbePath" 3
  if ("$c" -notmatch $Accept) { Die "Le répartiteur ne répond pas correctement sur $LbUrl$ProbePath (HTTP $c) : 'vagrant up lb1' ?" }
  $state = [hashtable]::Synchronized(@{ Stop = $false })
  $bag = New-Object 'System.Collections.Concurrent.ConcurrentBag[string]'
  $fn = ${function:Get-HttpCode}.ToString()
  $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $ChargeWorkers)); $pool.Open()
  $worker = { param($Url, $Delay, $Accept, $state, $bag, $fn)
    Invoke-Expression "function Get-HttpCode { $fn }"
    while (-not $state.Stop) {
      $c = Get-HttpCode $Url 3; $bag.Add("$c"); if ("$c" -notmatch $Accept) { $bag.Add("ERR $((Get-Date).ToString('HH:mm:ss')) HTTP $c") }
      Start-Sleep -Milliseconds ([int]($Delay * 1000)) } }
  $hs = @()
  for ($i = 0; $i -lt $ChargeWorkers; $i++) {
    $ps = [powershell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument("$LbUrl$ProbePath").AddArgument($ChargeDelay).AddArgument($Accept).AddArgument($state).AddArgument($bag).AddArgument($fn)
    $hs += [pscustomobject]@{ P = $ps; A = $ps.BeginInvoke() }
  }
  $script:ChargeCtx = [pscustomobject]@{ State = $state; Bag = $bag; Pool = $pool; Hs = $hs }
  Start-Sleep -Seconds 2; Ok 'charge en cours'
}
$script:Erreurs = 0
function Charge-Stop {
  $c = $script:ChargeCtx; if (-not $c) { return }
  $c.State.Stop = $true
  foreach ($h in $c.Hs) { try { [void]$h.P.EndInvoke($h.A) } catch { }; $h.P.Dispose() }; $c.Pool.Close(); $script:ChargeCtx = $null
  $items = @($c.Bag.ToArray()); $codes = @($items | Where-Object { $_ -notlike 'ERR *' }); $errs = @($items | Where-Object { $_ -like 'ERR *' })
  $script:Erreurs = $errs.Count
  Titre 'Bilan de la charge'
  Info "Requêtes émises : $($codes.Count)"
  Info ("Codes HTTP      : " + ((@($codes | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Count)x$($_.Name)" })) -join '  '))
  if ($script:Erreurs -eq 0) { Ok '0 requête en erreur pendant tout le déploiement' }
  else { Warn "$($script:Erreurs) requête(s) en erreur (voir ci-dessous)"; $errs | Select-Object -First 10 | ForEach-Object { Write-Host "      $($_.Substring(4))" } }
}

function Cleanup {
  if ($script:ChargeCtx) { try { Charge-Stop } catch { } }
  if ($script:HapOk -and $script:Drained.Count -gt 0) {
    foreach ($s in @($script:Drained)) { [void](Hap "set server $s state ready"); Info "serveur $s remis en service" }
  }
  Remove-Item -Force -ErrorAction SilentlyContinue $RemoteLocal
}

# ---------- Script exécuté DANS les VM applicatives (en root), embarqué ----------
# Écrit dans config/.cd-remote.sh (dossier synchronisé : visible dans les VM sous /vagrant/config).
$RemoteScript = @'
#!/bin/bash
# =============================================================================
#  cd-remote.sh — étape de déploiement exécutée DANS une VM applicative (en root)
#  Appelé par cd.sh (Linux/macOS/WSL/Git Bash) et cd.ps1 (Windows) : la logique
#  de déploiement est ICI, une seule fois, pour que les deux versions ne divergent jamais.
#
#  Usage : bash cd-remote.sh <info|deploy|rollback> [délai_santé_s] [force 0|1]
#  Sortie : des lignes d'information, puis UNE ligne "RESULT=<code> ..." lue par l'hôte.
#
#  Idempotence (mêmes paramètres => même état final, sans effet de bord) :
#   - La "version" d'un déploiement est l'empreinte SHA-256 (12 premiers caractères) de
#     dist/index.js. deploy ne fait RIEN (RESULT=UNCHANGED) si la version en place est
#     déjà celle de la source : pas de redémarrage, et surtout pas d'écrasement de
#     /opt/app.prev, qui reste la dernière version DIFFÉRENTE (cible du retour arrière).
#   - rollback ne fait RIEN si le serveur est déjà sur la version précédente. Il ne
#     permute pas les deux versions : rejoué, il converge au lieu d'osciller A -> B -> A.
#     Pour ré-avancer, on relance simplement un déploiement.
#   - force=1 réinstalle et redémarre même si la version est identique (jamais de
#     sauvegarde dans ce cas : .prev n'est pas touché).
# =============================================================================
set -uo pipefail

ACTION="${1:-info}"; SANTE_TIMEOUT="${2:-60}"; FORCE="${3:-0}"
SRC=/vagrant/app/api; DST=/opt/app; PREV=/opt/app.prev; SVC=api-app
PORT=$(awk -F= '$1=="PORT" {print $2}' "/etc/${SVC}.env" 2>/dev/null | tr -d '\r' | tail -1); PORT="${PORT:-80}"

# Empreinte courte du bundle d'un répertoire ("aucune" s'il n'y en a pas)
hash_de() {
  if [ -f "$1/dist/index.js" ]; then sha256sum "$1/dist/index.js" | cut -c1-12; else echo "aucune"; fi
}

attendre_sante() {
  local code
  for _ in $(seq 1 "$SANTE_TIMEOUT"); do
    if systemctl is-active --quiet "$SVC"; then
      code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/sante" || true)
      if [ "$code" = "200" ]; then
        code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/resultat" || true)
        case "$code" in 2*|4*) return 0 ;; esac    # sans paramètre : 400 attendu = route vivante
      fi
    fi
    sleep 1
  done
  return 1
}

installer() {   # installer <répertoire source> : recopie le code, sans toucher à ce qui est inchangé
  rsync -a --delete --exclude node_modules --exclude .git --exclude '/.env' --exclude 'dist/package.json' "$1/" "$DST/"
  # .env : copie nettoyée des fins de ligne Windows (CRLF), lisible par root seul (cf. app.sh)
  if [ -f "$1/.env" ]; then
    tr -d '\r' < "$1/.env" > "$DST/.env.tmp" && chmod 600 "$DST/.env.tmp" && mv "$DST/.env.tmp" "$DST/.env"
  else
    rm -f "$DST/.env"
  fi
  echo '{"type":"module"}' > "$DST/dist/package.json"     # le bundle est un module ES (cf. app.sh)
}
sauvegarder() {   # copie atomique de la version en place vers $PREV
  rm -rf "$PREV.tmp"; mkdir -p "$PREV.tmp"; rsync -a "$DST/" "$PREV.tmp/"
  rm -rf "$PREV"; mv "$PREV.tmp" "$PREV"
}

[ -d "$DST" ] || { echo "ERREUR : $DST absent, l'application n'a jamais été provisionnée (vagrant provision $(hostname))"; echo "RESULT=ERREUR"; exit 1; }
AVANT=$(hash_de "$DST")

case "$ACTION" in
  info)
    echo "RESULT=INFO CURRENT=$AVANT PREV=$(hash_de "$PREV") SOURCE=$(hash_de "$SRC")"
    exit 0 ;;

  deploy)
    CIBLE=$(hash_de "$SRC")
    [ "$CIBLE" != "aucune" ] || { echo "ERREUR : $SRC/dist/index.js introuvable (dossier app/api non synchronisé ?)"; echo "RESULT=ERREUR"; exit 1; }
    if [ "$AVANT" = "$CIBLE" ] && [ "$FORCE" != "1" ] && systemctl is-active --quiet "$SVC"; then
      echo "Version $CIBLE déjà en place et service actif : rien à faire."
      echo "RESULT=UNCHANGED AVANT=$AVANT APRES=$AVANT"; exit 0
    fi
    SAUVE=0
    if [ "$AVANT" != "$CIBLE" ]; then sauvegarder; SAUVE=1; fi   # .prev = dernière version DIFFÉRENTE
    installer "$SRC"
    systemctl restart "$SVC"
    if attendre_sante; then echo "RESULT=OK AVANT=$AVANT APRES=$(hash_de "$DST")"; exit 0; fi
    echo "La nouvelle version ne devient pas saine : retour arrière"
    journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null | sed 's/^/   journal : /'
    if [ "$SAUVE" -eq 1 ]; then
      installer "$PREV"; systemctl restart "$SVC"
      if attendre_sante; then echo "RESULT=ROLLED_BACK AVANT=$AVANT APRES=$(hash_de "$DST")"; exit 2; fi
    fi
    echo "RESULT=BROKEN AVANT=$AVANT"; exit 3 ;;

  rollback)
    P=$(hash_de "$PREV")
    [ "$P" != "aucune" ] || { echo "ERREUR : aucune version précédente ($PREV)"; echo "RESULT=ERREUR"; exit 1; }
    if [ "$AVANT" = "$P" ] && [ "$FORCE" != "1" ] && systemctl is-active --quiet "$SVC"; then
      echo "Déjà sur la version précédente ($P) : rien à faire."
      echo "RESULT=UNCHANGED AVANT=$AVANT APRES=$AVANT"; exit 0
    fi
    installer "$PREV"          # .prev reste inchangé : rejouer --rollback ne change plus rien
    systemctl restart "$SVC"
    if attendre_sante; then echo "RESULT=OK AVANT=$AVANT APRES=$(hash_de "$DST")"; exit 0; fi
    echo "RESULT=BROKEN AVANT=$AVANT"; exit 3 ;;

  *) echo "Action inconnue : $ACTION"; echo "RESULT=ERREUR"; exit 1 ;;
esac
'@

function Main {
  if (-not (Test-Path $FichierNoeuds)) { Die "$FichierNoeuds introuvable : lancez d'abord 'vagrant up' (le Vagrantfile le génère)" }
  if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) { Die 'vagrant est introuvable dans le PATH' }

  # Lecture de la source de vérité
  $noeuds = @(); $nom = $null; $ip = $null
  foreach ($l in (Get-Content $FichierNoeuds)) {
    $l = $l.TrimEnd("`r")
    if ($l -match '^- :nom:\s*(\S+)') { $nom = $Matches[1] } elseif ($l -match '^\s+:ip:\s*(\S+)') { $ip = $Matches[1] }
    elseif ($l -match '^\s+:role:\s*(\S+)') { $noeuds += [pscustomobject]@{ Nom = $nom; Ip = $ip; Role = $Matches[1] } }
  }
  $filtre = @($Only -split '[,; ]+' | Where-Object { $_ })
  $apps = @($noeuds | Where-Object { $_.Role -eq 'app' -and ($filtre.Count -eq 0 -or $filtre -contains $_.Nom) })
  if ($apps.Count -eq 0) { Die "Aucun serveur applicatif trouvé dans $FichierNoeuds$(if ($Only) { " pour -Only $Only" })" }

  Titre "Plan : $Action"
  $enLigne = @()
  foreach ($a in $apps) {
    if ($DryRun) { Info "$($a.Nom) ($($a.Ip))"; $enLigne += $a; continue }
    if ((Etat-Vm $a.Nom) -eq 'running') { $enLigne += $a; Info "$($a.Nom) ($($a.Ip)) : en ligne" } else { Warn "$($a.Nom) ($($a.Ip)) : VM arrêtée, ignorée" }
  }
  if ($DryRun) { Info "répartiteurs : $($LbVms -join ' ') | charge : $Charge ($ChargeWorkers travailleurs) | build : $(if ($NoBuild) { 0 } elseif ($Build) { 1 } else { 'auto' }) | force : $ForceN"; return 0 }
  if ($enLigne.Count -eq 0) { Die 'Aucun serveur applicatif en ligne (vagrant up)' }

  # Copie du script exécuté dans les VM, fins de ligne LF et sans BOM (sinon bash échoue)
  $txt = $RemoteScript -replace "`r`n", "`n" -replace "`r", ''
  [IO.File]::WriteAllText($RemoteLocal, $txt, (New-Object System.Text.UTF8Encoding($false)))

  # Capacités HAProxy
  foreach ($l in $LbVms) {
    if ((Etat-Vm $l) -ne 'running') { Warn "$l : VM arrêtée, ignorée pour le drain"; continue }
    if ((Vm $l "sudo test -S $HapSock && echo oui").Trim() -ne 'oui') { Warn "$l : pas de socket HAProxy ($HapSock)"; continue }
    if ((Vm $l 'command -v socat >/dev/null || sudo apt-get install -y -qq socat >/dev/null 2>&1; command -v socat >/dev/null && echo oui') -match 'oui') { $script:HapVms += $l } else { Warn "$l : socat indisponible" }
  }
  $script:HapOk = ($script:HapVms.Count -gt 0)
  if ($script:HapOk) { Ok "Socket d'administration HAProxy disponible sur $($script:HapVms -join ' ') : drain activé" }
  else {
    Warn "Aucun répartiteur avec socket HAProxy ($HapSock sur $($LbVms -join ' ')) : PAS de drain."
    Warn "Rejouez 'vagrant provision lb1 lb2' : lb1.sh/lb2.sh à jour déclarent le socket dans la section 'global'."
    if ($Action -ne 'status') { Warn 'Sans drain, les requêtes en vol sur le serveur redémarré peuvent être coupées.' }
  }
  $serversState = ''; if ($script:HapOk) { $serversState = Hap-Sur $script:HapVms[0] 'show servers state' }

  # Versions en place (une interrogation par VM)
  $cur = @{}; $prv = @{}; $source = 'inconnue'
  foreach ($a in $enLigne) {
    $s = Remote $a.Nom 'info'
    if ((Champ $s 'RESULT') -ne 'INFO') { Die "$($a.Nom) : impossible de lire la version en place ($(($s -split "`n" | Where-Object { $_ } | Select-Object -Last 1)))" }
    $cur[$a.Nom] = Champ $s 'CURRENT'; $prv[$a.Nom] = Champ $s 'PREV'; $source = Champ $s 'SOURCE'
  }

  if ($Action -eq 'status') {
    Titre "État des serveurs applicatifs (version de la source : $source)"
    Write-Host ('   {0,-8} {1,-16} {2,-14} {3,-14} {4}' -f 'SERVEUR', 'IP', 'EN PLACE', 'PRÉCÉDENTE', 'HAPROXY')
    foreach ($a in $enLigne) {
      $st = '-'; if ($script:HapOk) { $s = Srv-Haproxy $serversState $a.Nom $a.Ip; if ($s) { $st = "$s : $(Hap-Statut $s)" } }
      Write-Host ('   {0,-8} {1,-16} {2,-14} {3,-14} {4}' -f $a.Nom, $a.Ip, $cur[$a.Nom], $prv[$a.Nom], $st)
    }
    return 0
  }

  # Compilation
  if ($Action -eq 'deploy') {
    Titre 'Compilation'
    $apiDir = Join-Path $Racine 'app\api'; $pkg = Join-Path $apiDir 'package.json'
    $aBuild = (Test-Path $pkg) -and ((Get-Content $pkg -Raw) -match '"build"')
    if (-not $NoBuild) {
      Push-Location $apiDir
      try {
        if ($env:BUILD_CMD) { & cmd.exe /c $env:BUILD_CMD; if ($LASTEXITCODE -ne 0) { Die 'La compilation a échoué (BUILD_CMD)' } }
        elseif ((Get-Command bun -ErrorAction SilentlyContinue) -and $aBuild) { & bun run build; if ($LASTEXITCODE -ne 0) { Die 'La compilation a échoué (bun run build)' } }
        elseif ((Get-Command npm -ErrorAction SilentlyContinue) -and $aBuild) { & npm run build; if ($LASTEXITCODE -ne 0) { Die 'La compilation a échoué (npm run build)' } }
        elseif ($Build) { Die "-Build demandé mais aucun outil de compilation (bun/npm + script 'build') trouvé" }
        else { Warn 'Aucun outil de compilation détecté : utilisation de dist\index.js existant' }
      } finally { Pop-Location }
    } else { Info 'compilation ignorée (-NoBuild)' }
    $bundle = Join-Path $apiDir 'dist\index.js'
    if (-not (Test-Path $bundle)) { Die 'app\api\dist\index.js introuvable : compilez l''API d''abord' }
    $source = Champ (Remote $enLigne[0].Nom 'info') 'SOURCE'
    if (-not $source -or $source -eq 'aucune') { Die 'dist/index.js n''est pas visible depuis les VM (dossier app/api non synchronisé ?)' }
    Ok "Version à déployer : $source ($((Get-Item $bundle).Length) octets)"
  }

  # Décision : qui doit changer ? (idempotence)
  Titre 'Décision par serveur'
  $aFaire = @(); $aSauter = @()
  foreach ($a in $enLigne) {
    $c = $cur[$a.Nom]; $p = $prv[$a.Nom]
    if ($Action -eq 'deploy') {
      if ($c -eq $source -and -not $Force) { Info "$($a.Nom) : déjà à la version $c -> sauté"; $aSauter += [pscustomobject]@{ N = $a.Nom; V = $c; R = 'déjà à jour' }; continue }
      Info "$($a.Nom) : $c -> $source"
    } else {
      if ($p -eq 'aucune') { Warn "$($a.Nom) : aucune version précédente -> sauté"; $aSauter += [pscustomobject]@{ N = $a.Nom; V = $c; R = 'pas de version précédente' }; continue }
      if ($c -eq $p -and -not $Force) { Info "$($a.Nom) : déjà sur la version précédente ($c) -> sauté"; $aSauter += [pscustomobject]@{ N = $a.Nom; V = $c; R = 'déjà revenu' }; continue }
      Info "$($a.Nom) : $c -> $p"
    }
    $aFaire += $a
  }
  if ($aFaire.Count -eq 0) {
    if ($Action -eq 'rollback' -and @($aSauter | Where-Object { $_.R -eq 'pas de version précédente' }).Count -gt 0) { Die 'Retour arrière impossible : au moins un serveur n''a pas de version précédente (aucun déploiement antérieur).' }
    Ok 'Rien à faire : aucun serveur n''a été touché (idempotent).'; return 0
  }
  if ($enLigne.Count -lt 2 -and -not $AllowSingle) { Die 'Un seul serveur en ligne : le retirer provoquerait une COUPURE. Démarrez-en un second (ou -AllowSingle).' }

  if ($Charge) { Charge-Start }
  $recap = @(); $statut = 0; $debut = Get-Date
  foreach ($a in $aFaire) {
    $nomS = $a.Nom; $t0 = Get-Date; Titre "$nomS ($($a.Ip))"
    $srv = ''
    if ($script:HapOk) { $srv = Srv-Haproxy $serversState $nomS $a.Ip; if (-not $srv) { Warn "$nomS introuvable dans HAProxy (configuration lb à vérifier) : pas de drain" } }
    if ($srv) {
      foreach ($b in $enLigne) {
        if ($b.Nom -eq $nomS) { continue }
        $o = Srv-Haproxy $serversState $b.Nom $b.Ip; if (-not $o) { continue }
        if ((Hap-Statut $o) -notlike 'UP*') { Die "$($b.Nom) n'est pas UP dans HAProxy : on ne retire pas un second serveur (déploiement interrompu avant $nomS)" }
      }
      Info "drain de $srv dans HAProxy..."; [void](Hap "set server $srv state drain"); [void]$script:Drained.Add($srv); Attendre-Drain $srv
    }
    Info "installation ($Action) et redémarrage..."
    $sortie = Remote $nomS $Action
    ($sortie -split "`n") | Where-Object { $_ -and $_ -notmatch '^RESULT=' } | ForEach-Object { Write-Host "      $_" }
    $res = Champ $sortie 'RESULT'; $av = Champ $sortie 'AVANT'; $ap = Champ $sortie 'APRES'
    switch ($res) {
      'OK'          { Ok "${nomS} : $av → $ap" }
      'UNCHANGED'   { Ok "${nomS} : déjà à jour ($ap)" }
      'ROLLED_BACK' { Warn "${nomS} : nouvelle version refusée, ancienne version restaurée ($ap)"; $statut = 2 }
      'BROKEN'      { Warn "${nomS} : hors service même après retour arrière (laissé en drain)"; $statut = 3 }
      default       { Warn "${nomS} : échec de l'étape de déploiement ($(if ($res) { $res } else { 'aucune réponse' }))"; $statut = 1 }
    }
    if ($srv -and $res -ne 'BROKEN') {
      [void](Hap "set server $srv state ready")
      if (Attendre-Up $srv) { Ok "$srv : UP dans HAProxy" }
      $script:Drained.Remove($srv)
    }
    $recap += ('{0,-8} {1,-14} → {2,-14} {3,-12} {4}s' -f $nomS, $av, $ap, $res, [int]((Get-Date) - $t0).TotalSeconds)
    if ($statut -ne 0) { Warn 'Déploiement INTERROMPU : les serveurs suivants n''ont pas été touchés.'; break }
  }

  Charge-Stop
  Titre "Récapitulatif (durée totale : $([int]((Get-Date) - $debut).TotalSeconds) s)"
  Write-Host ('   {0,-8} {1,-14}   {2,-14} {3,-12} {4}' -f 'SERVEUR', 'AVANT', 'APRÈS', 'RÉSULTAT', 'DURÉE')
  foreach ($l in $recap) { Write-Host "   $l" }
  foreach ($s in $aSauter) { Write-Host ('   {0,-8} {1,-14}   {2,-14} {3,-12} {4}' -f $s.N, $s.V, $s.V, 'SAUTÉ', "($($s.R))") }
  if ($statut -ne 0) { return $statut }
  if ($script:Erreurs -gt 0) { return 4 }
  Ok 'Déploiement terminé sans coupure.'; return 0
}

$rc = 0
try { $rc = Main }
catch {
  $m = "$($_.Exception.Message)"
  if ($m -like 'CDDIE|*') { $p = $m.Split('|', 3); Write-Host "ERREUR : $($p[2])" -ForegroundColor Red; $rc = [int]$p[1] }
  else { Write-Host "ERREUR inattendue : $m" -ForegroundColor Red; Write-Host $_.ScriptStackTrace; $rc = 1 }
}
finally { Cleanup }
exit $rc
