# Робить full бекапи на преферд сервері якщо і диск К і бд живі, і робить лог бекапи і на секондарі сервері коли на преферд відпав диск К
# сервери входять в Availability group
$ErrorActionPreference = "Stop" # режим переривання помилок
Set-Location "C:\"  # Фікс для SQL Agent: примусово виходимо з SQL-провайдера на диск C:
$disk = "K:\"
$fold_back = "SQLbackup"
$zakin = "bak"
$dbname = "vpn_serv01"
$cur_serv = $env:COMPUTERNAME
if ($cur_serv -eq "sqlserv03") {  $rem_serv = "sqlserv04"
} else {  $rem_serv = "sqlserv03" }
$local_path = "$disk$fold_back"
$net_path   = "\\$rem_serv\${fold_back}$"    # це диск на віддаленому сервеку
$sqlquery = "SELECT sys.fn_hadr_backup_is_preferred_replica('$dbname') as ColomPref"    # Перевірка ролі в Always On
$pref_serv = (Invoke-sqlcmd -Query $sqlquery -ServerInstance ".").ColomPref             # Перевірка ролі в Always On
$locdiskexist = [System.IO.Directory]::Exists($local_path)  #  Надійніша .NET перевірка локального диску замість класичного Test-Path 
$remdiskexist = [System.IO.Directory]::Exists($net_path)    #  Надійніша .NET перевірка мережевої папки замість класичного Test-Path
$sqlquery2 = "SELECT state_desc as StateDB FROM sys.databases WHERE name = '$dbname'"     # перевірка стану бд - початок
$dbresult = Invoke-Sqlcmd -Database master -Query $sqlquery2 -ServerInstance $cur_serv
if ($dbresult) {  $locdbstat = $dbresult.StateDB
} else {  $locdbstat = "NOT_FOUND_DB"  }                                                  # перевірка стану бд - кінець
 # ------------------------------------------ Це виконається тільки на Преферд сервері -------------------------------------
if ($pref_serv -eq 1) {     
    if ($locdiskexist -eq $true -and $locdbstat -eq "ONLINE") {    # --- Якщо диск і бд живі
       Write-Output "This primary replica, local backup disk {$disk} and {$dbname} is OK. Lets make full backup"
       $DateStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
       $full_name_back = $local_path + "\" + $dbname + "_FUL_"+ $DateStamp + "." + $zakin      # так буде називатися наш файл бекапу логу
       $BackupQuery = "BACKUP DATABASE [$dbname] TO DISK = N'$full_name_back' WITH NOFORMAT, NOINIT, SKIP, NOREWIND, NOUNLOAD, STATS = 10"
       try {  # тут робиться бекап якщо все Ок інакше йдемо в catch із виводом помилок якщо failed
          Invoke-Sqlcmd -ServerInstance $cur_serv -Database "master" -Query $BackupQuery   
          Write-Output "Fullbackup successfully made on {$cur_serv} for db: {$dbname}."
          exit 0    # нормально виходимо із цілого скрипта
       }   catch { Write-Error "Fullbackup failed on {$cur_serv} for db: {$dbname}. Error: $_"}
    }  elseif ($locdiskexist -eq $false) {              # Якщо диск К - відсутній/впав
          throw "Critical: server is primary but local backup disk [$local_path] is not accessable!" 
    }  elseif ($locdbstat -ne "ONLINE") {                # Якщо БД не ONLINE/впала
          throw "Critical: server is primary but DB [$dbname] is not ONLINE." 
       }   # виходимо аварійно щоб SQL Agent дав красний крестик  
} else  {     #  -------------------- Це виконається тільки на НЕ Преферд - СЕКОНДАРІ сервері --------------------------------------------
              #  на секонд репліці fullbackup робиться з опцією copy_only, бо це не впливає на загал ланцюжок резервного копіювання
            $DateStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
            $full_name_back = $local_path + "\" + $dbname + "_FUL_"+ $DateStamp + "." + $zakin      # так буде називатися наш файл бекапу логу
            $BackupQuery = "BACKUP DATABASE [$dbname] TO DISK = N'$full_name_back' WITH NOFORMAT, NOINIT, SKIP, NOREWIND, NOUNLOAD, STATS = 10, COPY_ONLY" 
            #  якщо на ПРЕФЕРД сервері відпав диск К, але на секондарі сервері диск К і бд - живі, то немає сенсу чекати 240 с а зразу робимо
            if ($remdiskexist -ne $true -and $locdiskexist -eq $true -and $locdbstat -eq "ONLINE")  {    
                Write-Output "The disk ($disk) is off, on preffered server ($rem_serv). Lets try to make on secondary ($cur_serv)."
                try {    # тут робиться бекап якщо все Ок інакше йдемо в catch із виводом помилок якщо failed
                   Invoke-Sqlcmd -ServerInstance $cur_serv -Database "master" -Query $BackupQuery  # робимо full backup на НЕ преферд сервері
                   Write-Output "SUCCESS: FULL backup for ${dbname} completed successfully on ${cur_serv}."
                   exit 0  # спокійний вихід із проги
                }  catch { Write-Error "Fullbackup failed on {$cur_serv} for db: {$dbname}. Error: $_" }   
             # якщо на ПРЕФЕРД сервері не відпав диск К, і на секондарі живий диск К і бд то     
            }  elseif ($remdiskexist -eq $true -and $locdiskexist -eq $true -and $locdbstat -eq "ONLINE")  {           # якщо на ПРЕФЕРД сервері не відпав диск К
                 Write-Output "This is NON-preferred replica. Waiting 5 minutes to check is made full backup on preferred server?"
                 Start-Sleep -Seconds 300
                 # запитуємо в віддаленого (преферд) сервака чи в нього є свіжий бекап за остані там кілька хвилин вже зроблений ?
                 $sqlquery3 = "SELECT TOP 1 1 AS BackupDone FROM msdb.dbo.backupset WHERE database_name = '$dbname'  
                    AND type = 'D' AND backup_start_date > DATEADD(minute, -6, GETDATE());"   # запитуємо в віддаленого (преферд) сервака
                 $ismadebackup = (Invoke-Sqlcmd -ServerInstance $rem_serv -Database msdb -Query $sqlquery3) 
                 if ($ismadebackup -and $ismadebackup.BackupDone -eq 1)  {  # Якщо бекап зроблений на ПРЕФЕРД серваку 
                     Write-Output "Full backup made on preferred server ($rem_serv). Here dont make it!"
                     exit 0    #  Все спокійно виходимо з коду, нічого далі не виконуємо, бо бекап вже зроблений на преферд
                 }  else {     # Якщо бекап НЕ зроблений на ПРЕФЕРД серваку тоді робимо його на секондарі серваку
                       Write-Output "Full backup is not made on preffered server ($rem_serv). Lets try to make on secondary ($cur_serv)."
                       try {   # тут робиться бекап якщо все Ок інакше йдемо в catch із виводом помилок якщо failed
                          Invoke-Sqlcmd -ServerInstance $cur_serv -Database "master" -Query $BackupQuery 
                          Write-Output "SUCCESS: Full backup for ${dbname} completed successfully on ${cur_serv}."
                       }  catch { Write-Error "Fullbackup failed on {$cur_serv} for db: {$dbname}. Error: $_" }
                    }  
               }  else { throw "Critical: server is NON preferred but DB [$dbname]  or disk [$local_path] is not ONLINE." }     
        }                 
       
