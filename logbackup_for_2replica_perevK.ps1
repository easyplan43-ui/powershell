# Робить лог бекапи на преферд сервері якщо і диск К і бд живі, і робить лог бекапи і на секондарі сервері коли на преферд відпав диск К
# сервери входять в Availability group
$ErrorActionPreference = "Stop" # режим переривання помилок
Set-Location "C:\"  # Фікс для SQL Agent: примусово виходимо з SQL-провайдера на диск C:
$disk = "K:\"
$fold_back = "SQLlogback"
$zakin = "trn"
$dbname = "vpn_serv01"
$cur_serv = $env:COMPUTERNAME
if ($cur_serv -eq "sqlserv03") {  $rem_serv = "sqlserv04"
} else {  $rem_serv = "sqlserv03" }
$local_path = "$disk$fold_back"
$net_path   = "\\$rem_serv\${fold_back}$"    # це диск на віддаленому сервеку
$sqlquery = "SELECT sys.fn_hadr_backup_is_preferred_replica('$dbname') as ColomPref" # Перевірка ролі в Always On
$pref_serv = (Invoke-sqlcmd -Query $sqlquery -ServerInstance ".").ColomPref
$locdiskexist = Test-Path $local_path  #  перевірка локального диску
$remdiskexist = [System.IO.Directory]::Exists($net_path)  # Надійніша .NET перевірка мережевої папки замість класичного Test-Path
$sqlquery2 = "SELECT state_desc as StateDB FROM sys.databases WHERE name = '$dbname'"  # перевірка стану бд
$dbresult = Invoke-Sqlcmd -Database master -Query $sqlquery2 -ServerInstance $cur_serv
if ($dbresult) {  $locdbstat = $dbresult.StateDB
} else {  $locdbstat = "NOT_FOUND_DB"  }
 # ------------------------------------------ Це виконається тільки на Преферд сервері -------------------------------------
if ($pref_serv -eq 1) {     
    if ($locdiskexist -eq $true -and $locdbstat -eq "ONLINE") {    # --- Якщо диск і бд живі
       Write-Output "This primary replica, local backup disk {$disk} and {$dbname} is OK. Lets make log backup"
       $DateStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
       $full_name_back = $local_path + "\" + $dbname + "_LOG_"+ $DateStamp + "." + $zakin      # так буде називатися наш файл бекапу логу
       $BackupQuery = "BACKUP LOG [$dbname] TO DISK = N'$full_name_back' WITH NOFORMAT, NOINIT, SKIP, NOREWIND, NOUNLOAD, STATS = 10"
       Invoke-Sqlcmd -ServerInstance $cur_serv -Database "master" -Query $BackupQuery   # тут робиться бекап
       Write-Output "Log backup successfully made on {$cur_serv} for db: {$dbname}."
       exit 0    # нормально виходимо із цілого скрипта
    }  elseif ($locdiskexist -eq $false) {              # Якщо диск К - відсутній/впав
          throw "Critical: server is primary but local backup disk [$local_path] is not accessable!" 
    }  elseif ($locdbstat -ne "ONLINE") {                # Якщо БД не ONLINE/впала
          throw "Critical: server is primary but DB [$dbname] is not ONLINE." 
       }   # виходимо аварійно щоб SQL Agent дав красний крестик  
} else  {     #  -------------------- Це виконається тільки на НЕ Преферд - СЕКОНДАРІ сервері --------------------------------------------
            $DateStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
            $full_name_back = $local_path + "\" + $dbname + "_LOG_"+ $DateStamp + "." + $zakin      # так буде називатися наш файл бекапу логу
            $BackupQuery = "BACKUP LOG [$dbname] TO DISK = N'$full_name_back' WITH NOFORMAT, NOINIT, SKIP, NOREWIND, NOUNLOAD, STATS = 10" 
            #  якщо на ПРЕФЕРД сервері відпав диск К, але на не преферд сервері диск К і бд - живі, то немає сенсу чекати 240 с а зразу робимо
            if ($remdiskexist -ne $true -and $locdiskexist -eq $true -and $locdbstat -eq "ONLINE")  {    
                Write-Output "The disk ($disk) is off, on preffered server ($rem_serv). Lets try to make on secondary ($cur_serv)."
                Invoke-Sqlcmd -ServerInstance $cur_serv -Database "master" -Query $BackupQuery  # робимо Log backup на НЕ преферд сервері
                Write-Output "SUCCESS: Log backup for ${dbname} completed successfully on ${cur_serv}."
                exit 0  # спокійний вихід із проги
            }  else {           # якщо на ПРЕФЕРД сервері не відпав диск К
                 Write-Output "This is NON-preferred replica. Waiting 4 minutes to check is made log backup on preferred server?"
                 Start-Sleep -Seconds 240
                 $sqlquery3 = "SELECT TOP 1 1 AS BackupDone FROM msdb.dbo.backupset WHERE database_name = '$dbname'  
                    AND type = 'L' AND backup_start_date > DATEADD(minute, -6, GETDATE());"   # запитуємо в віддаленого (преферд) сервака
                 $ismadebackup = (Invoke-Sqlcmd -ServerInstance $rem_serv -Database msdb -Query $sqlquery3) 
                 if ($ismadebackup -and $ismadebackup.BackupDone -eq 1)  {  # Якщо бекап зроблений на ПРЕФЕРД серваку 
                     Write-Output "Log backup made on preferred server ($rem_serv). Here dont make it!"
                     exit 0    #  Все спокійно виходимо з коду, нічого далі не виконуємо, бо бекап вже зроблений на преферд
                 }  else {     # Якщо бекап НЕ зроблений на ПРЕФЕРД серваку тоді робимо його на секондарі серваку
                       Write-Output "Log backup is not made on preffered server ($rem_serv). Lets try to make on secondary ($cur_serv)."
                       if ($locdiskexist -eq $true -and $locdbstat -eq "ONLINE") {   # Якщо на СЕКОНДАРІ серваку і диск живий і бд жива
                           Invoke-Sqlcmd -ServerInstance $cur_serv -Database "master" -Query $BackupQuery 
                           Write-Output "SUCCESS: Log backup for ${dbname} completed successfully on ${cur_serv}."
                           exit 0
                       }  elseif ($locdiskexist -eq $false) {   # Якщо на СЕКОНДАРІ сервері диск К - відсутній/впав
                              Write-Warning "Critical: server is NON preferred but local backup disk [$local_path] is not accessable!" 
                       }  elseif ( $locdbstat -ne "ONLINE") {   # Якщо на СЕКОНДАРІ сервері БД - відсутня/впала
                              throw "Critical: server is NON preferred but DB [$dbname] is not ONLINE." 
                          }
                    }  
            }                
        }
