# Робить differential бекапи на тільки на преферд сервері якщо і диск К і бд живі, а на секондарі сервері робити diff бекапи ЗАБОРОНЕНО
# сервери входять в Availability group
$ErrorActionPreference = "Stop" # режим переривання помилок
Set-Location "C:\"  # Фікс для SQL Agent: примусово виходимо з SQL-провайдера на диск C:
$disk = "K:\"
$fold_back = "SQLdiffback"
$zakin = "diff"
$dbname = "vpn_serv01"
$cur_serv = $env:COMPUTERNAME
if ($cur_serv -eq "sqlserv03") {  $rem_serv = "sqlserv04"
} else {  $rem_serv = "sqlserv03" }
$local_path = "$disk$fold_back"
$net_path   = "\\$rem_serv\${fold_back}$"    # це диск на віддаленому сервеку
$sqlquery = "SELECT sys.fn_hadr_backup_is_preferred_replica('$dbname') as ColomPref" # Перевірка ролі в Always On
$pref_serv = (Invoke-sqlcmd -Query $sqlquery -ServerInstance ".").ColomPref
$locdiskexist = [System.IO.Directory]::Exists($local_path)  # Надійніша .NET перевірка мережевої папки замість класичного Test-Path
$remdiskexist = [System.IO.Directory]::Exists($net_path)    #  Надійніша .NET перевірка мережевої папки замість класичного Test-Path
$sqlquery2 = "SELECT state_desc as StateDB FROM sys.databases WHERE name = '$dbname'"  # перевірка стану бд
$dbresult = Invoke-Sqlcmd -Database master -Query $sqlquery2 -ServerInstance $cur_serv
if ($dbresult) {  $locdbstat = $dbresult.StateDB
} else {  $locdbstat = "NOT_FOUND_DB"  }
 # ------------------------------------------ Це виконається тільки на Преферд сервері -------------------------------------
if ($pref_serv -eq 1) {     
    if ($locdiskexist -eq $true -and $locdbstat -eq "ONLINE") {    # --- Якщо диск і бд живі то робимо бекап на 
       Write-Output "This primary replica, local backup disk {$disk} and {$dbname} is OK. Lets make diff backup"
       $DateStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
       $full_name_back = $local_path + "\" + $dbname + "_DIF_"+ $DateStamp + "." + $zakin      # так буде називатися наш файл бекапу логу
       $BackupQuery = "BACKUP DATABASE [$dbname] TO DISK = N'$full_name_back' WITH DIFFERENTIAL, NOFORMAT, NOINIT, SKIP, NOREWIND, NOUNLOAD, STATS = 10"
       try {
          Invoke-Sqlcmd -ServerInstance $cur_serv -Database "master" -Query $BackupQuery   # тут робиться бекап
          Write-Output "Diff backup successfully made on {$cur_serv} for db: {$dbname}."
          exit 0    # нормально виходимо із цілого скрипта
       } catch {  Write-Error "Diffbackup failed on {$cur_serv} for db: {$dbname}. Error: $_" }   
         # Якщо диск К впав на праймері сервері але бд на праймері жива і диск К живий на секондарі серв 
         # то робимо diffbackup на праймері серваку а скидаємо його на диск К секондарі сервака, бо К впав на праймері
    }  elseif ($locdiskexist -eq $false -and  $locdbstat -eq "ONLINE" -and $remdiskexist -eq $true) { 
          Write-Output "This primary replica, local backup disk {$disk} is OFF and {$dbname} is OK. Lets make diff backup on disk K secondary server."
          $DateStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
          $full_name_back = $net_path + "\" + $dbname + "_DIF_"+ $DateStamp + "." + $zakin      # так буде називатися наш файл бекапу логу 
          $BackupQuery = "BACKUP DATABASE [$dbname] TO DISK = N'$full_name_back' WITH DIFFERENTIAL, NOFORMAT, NOINIT, SKIP, NOREWIND, NOUNLOAD, STATS = 10"
          try {
             Invoke-Sqlcmd -ServerInstance $cur_serv -Database "master" -Query $BackupQuery   # тут робиться бекап  
             Write-Output "Diff backup successfully made on {$cur_serv} for db: {$dbname} and has written on K secondary server."
             exit 0    # нормально виходимо із цілого скрипта
          } catch { Write-Error "Diffbackup failed on {$cur_serv} for db: {$dbname}. Error: $_" }   
    }  elseif ($locdbstat -ne "ONLINE") {                # Якщо БД не ONLINE/впала
          throw "Critical: server is primary but DB [$dbname] is not ONLINE." 
       }   # виходимо аварійно щоб SQL Agent дав красний крестик  
} else  {     #  -------------------- Це виконається тільки на НЕ Преферд - СЕКОНДАРІ сервері --------------------------------------------
              # а на секондарі сервері робити differencial backup заборонено
            Write-Output "This is NON-preferred replica (Secondary). Diff backups are not supported here."
            exit 0   
        }                 
       
