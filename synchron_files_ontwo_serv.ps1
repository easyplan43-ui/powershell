# Проводить синхронізацію двох папок на двох різних SQL серваках в групі доступ Always ON 
$ErrorActionPreference = "Stop"
Set-Location "C:\"  # Фікс для SQL Agent: примусово виходимо з SQL-провайдера на диск C:
$disk = "K:\"
$fold_back = "SQLlogback"
$zakin = "*.trn"
$dbname = "vpn_serv01"
$cur_serv = $env:COMPUTERNAME
if ($cur_serv -eq "sqlserv03") {
    $rem_serv = "sqlserv04"
} else { $rem_serv = "sqlserv03" }
$local_path = "$disk$fold_back"
$net_path   = "\\$rem_serv\${fold_back}$"
try {
   $sqlquery = "SELECT sys.fn_hadr_backup_is_preferred_replica('$dbname') as ColomPref" # Перевірка ролі в Always On
   $psPrefer = (Invoke-sqlcmd -Query $sqlquery -ServerInstance "." -ErrorAction Stop).ColomPref
}  catch {   throw "Critical: Cannot connect to local SQL to check Always On role! Error: $_" }
$locdiskexist = Test-Path $local_path -ErrorAction SilentlyContinue #  перевірка локального диску
$remdiskexist = [System.IO.Directory]::Exists($net_path)  # Надійніша .NET перевірка мережевої папки замість класичного Test-Path
$PSNativeCommandUseErrorActionPreference = $false  # Тимчасово вимикаємо автоматичне падіння від кодів успіху Robocopy (наприклад, коду 1)
if ($psPrefer -eq 1)  {  # --------------------------------- Це виконається тільки на Преферд сервері ----------------------------------
    if ($locdiskexist -eq $true -and $remdiskexist -eq $true)  {  # Якщо є диск на преферд і на НЕ преферд серверах
       Write-Output "This preferred replica, local backup disk and remote backup disk is OK. Lets start synchronization"
       robocopy "$local_path" "$net_path" $zakin /XO /R:3 /W:5 /NP /NDL
       if($LASTEXITCODE -lt 8)  {    # якщо код який передав robocopy в $LASTEXITCODE менше за 8 - тоді це успіх
           Write-Output "Logs synchronized from preferred ($cur_serv) to secondary ($rem_serv). Robocopy code: $LASTEXITCODE"
           exit 0
       } else  {     # якщо robocopy передала код 8 в $LASTEXITCODE, тобто помилку  
           throw "Robocopy failed with exit code $LASTEXITCODE during synchronizing from preferred server"   }  
    }  elseif ($locdiskexist -eq $false) {   # Якщо диск на преферд відпав
          Write-Warning "Critical: server is primary but local backup disk [$local_path] is not accessable!" 
          exit 1     # виходимо аварійно  щоб SQL Agent дав красний крестик 
    }  elseif ($remdiskexist -eq $false) {  # Якщо диск на який копіюєм, тобто диск на НЕ преферд сервері - відпав
          Write-Warning "Critical: server is primary but backup disk [$net_path] on secondary Server [$rem_serv] is not accessable!"
          exit 1      # виходимо аварійно  щоб SQL Agent дав красний крестик 
    }   
}  else  {     #  -------------------- Це виконається тільки на НЕ Преферд СЕКОНДАРІ сервері ------------------------------------------ 
    if ($locdiskexist -eq $true -and $remdiskexist -eq $true)  {  # Якщо є диск на СЕКОНДАРІ і на  преферд серверах
       Write-Output "This secondary replica, local backup disk and remote backup disk is OK. Lets start synchronization"
       robocopy "$local_path" "$net_path" $zakin /XO /R:3 /W:5 /NP /NDL
       if ($LASTEXITCODE -lt 8) {  # якщо код який передав robocopy в $LASTEXITCODE менше за 8 - тоді це успіх
           Write-Output "SUCCESS: Secondary server ($cur_serv) synchronized logs to preferred ($rem_serv). Robocopy code: $LASTEXITCODE"
           exit 0
       } else { # якщо robocopy передала код 8 в $LASTEXITCODE, тобто помилку 
           throw "Error during synchronizing logs beetwen secondary and preferred servers!"
       }
    }  elseif ($locdiskexist -eq $false) {   # Якщо диск на CЕКОНДАРІ відпав
          Write-Warning "Critical: server is secondary but local backup disk [$local_path] is not accessable!" 
          exit 1      # виходимо аварійно  щоб SQL Agent дав красний крестик 
    }  elseif ($remdiskexist -eq $false) {  # Якщо диск на який копіюєм, тобто диск на преферд сервері - відпав
          Write-Warning "Critical: server is secondary but backup disk [$net_path] on preferred server [$rem_serv] is not accessable!"
          exit 1      # виходимо аварійно  щоб SQL Agent дав красний крестик 
    } 
}
