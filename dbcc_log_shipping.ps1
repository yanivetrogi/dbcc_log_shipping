Clear-Host;
Set-Location 'C:\';


#if ($psISE) { $path = Split-Path -Path $psISE.CurrentFile.FullPath; } else { $path = $global:PSScriptRoot; }
$path = $PSScriptRoot;

#region <Variables>

[string]$config_file_full_name = Join-Path $path 'config.json';
[PSCustomObject]$config_file = Get-Content  $config_file_full_name | Out-String| ConvertFrom-Json;

[bool]$user_interactive   = [Environment]::UserInteractive;
[string]$primary_server   = 'SQLPROD-01' ;
[string]$secondary_server = 'SQLPROD-02';
[string]$ApplicationName  = 'LogShippingDBCC';
[int]$sleep_interval      = 5;
[string]$primary_connection_string   = "Server=$primary_server;Database=master;Integrated Security=True;Application Name=$ApplicationName;";
[string]$secondary_connection_string = "Server=$secondary_server;Database=master;Integrated Security=True;Application Name=$ApplicationName;";

[string]$file_name = $MyInvocation.MyCommand.Name;

#endregion


#region <email>
[string]$use_default_credentials = $config_file.use_default_credentials;

if($use_default_credentials -eq $true)
{
    [string]$user     = $config_file.user;
    [string]$password = $config_file.password;

    [SecureString]$secuered_password = ConvertTo-SecureString $password -AsPlainText -Force;
    [System.Management.Automation.PSCredential]$credential = New-Object System.Management.Automation.PSCredential ($user, $secuered_password);
}

[string]$to          = $config_file.to;
[string]$from        = $config_file.from;
[string]$smtp_server = $config_file.smtp_server;

[Net.Mail.SmtpClient]$smtp_client = New-Object Net.Mail.SmtpClient($smtp_server);
if($use_default_credentials -eq $true)
{
    [object]$smtp_client.Credentials  = $credential;
}
[int32]$smtp_client.Port          = $config_file.port;
[bool]$smtp_client.EnableSsl      = $config_file.ssl;
[string]$subject;
#endregion


#region <Logging>
[string]$log4net_log = Join-Path $path 'dbcc_log_shipping.log';
[string]$log4net_dll = Join-Path $path 'log4net.dll';

[void][Reflection.Assembly]::LoadFile($log4net_dll);
[log4net.LogManager]::ResetConfiguration();

$FileAppender = new-object log4net.Appender.FileAppender(([log4net.Layout.ILayout](new-object log4net.Layout.PatternLayout('%date{yyyy-MM-dd HH:mm:ss.fff}  %level  %message%n')), $log4net_log, $True));
$FileAppender.Threshold = [log4net.Core.Level]::All;
[log4net.Config.BasicConfigurator]::Configure($FileAppender);

$Log=[log4net.LogManager]::GetLogger("root");
#endregion


function Get-TimeStamp {
    return (Get-Date).ToString('[yyyyMMdd HH:mm:ss]')
    };

function Get-SQLAgentJobStatus {
    Param ([string]$JobName, [string]$ConnectionString)


    $ConnectionString = $ConnectionString;        
    $CommandText = 
    'SET NOCOUNT ON;
     SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
     IF EXISTS
     (
         SELECT	
             j.name 
         FROM msdb.dbo.sysjobs_view j
         INNER JOIN msdb.dbo.sysjobactivity a ON j.job_id = a.job_id
         INNER JOIN (SELECT job_id
                             , MAX(session_id) max_session_id
                     FROM     msdb..sysjobactivity
                     GROUP BY job_id
	 		        ) ja ON a.job_id = ja.job_id AND a.session_id = ja.max_session_id
         WHERE run_Requested_date IS NOT NULL AND stop_execution_date IS NULL
         AND j.name = ''' + $Job_name + '''
     ) SELECT 1 ELSE SELECT 0;'    

    try{
        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
        $SqlCommand = $sqlConnection.CreateCommand();
        $SqlConnection.Open();
        $SqlCommand.CommandText = $CommandText;        
        $JobStatus = $SqlCommand.ExecuteScalar();    
        
        return $JobStatus;          
    }
    catch 
    {            
        $Log.Error($file_name + ':  ' + $_.Exception)
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red}; 
        throw $_;        
    }
}


# Get the list of databases.
#region <databases>
$database = 'master';
$CommandText = 'SELECT secondary_database FROM msdb.dbo.log_shipping_secondary_databases /* WHERE secondary_database IN (''ReportServertempdb'', ''ReportServer'')*/;';
$ConnectionString = $secondary_connection_string;

[System.Data.DataSet]$ds_Databases = New-Object System.Data.DataSet;

if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '- Geting the lis of databases to process...' -ForegroundColor Cyan};
try{
       $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
       $SqlCommand = $sqlConnection.CreateCommand();       
       $SqlConnection.Open();
       $SqlCommand.CommandText = $CommandText;       
       
       $SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter;
       $SqlAdapter.SelectCommand = $SqlCommand;    
       $SqlAdapter.Fill($ds_Databases);               
   }
catch 
   {            
       $Log.Error($file_name + ':  ' + $_.Exception)
       if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red};    
       throw $_;     
   }

#endregion



# Loop over the databases
foreach($Row in $ds_Databases.Tables[0].Rows)
{
    try{
        $database = $Row.secondary_database; 
        
        
        # secondary - modify restore_mode to 1        
        $CommandText = 'UPDATE msdb.dbo.log_shipping_secondary_databases SET restore_mode = 1, disconnect_users = 0, restore_delay = 0 WHERE secondary_database = ''' + $database +'''';  
        $ConnectionString = $secondary_connection_string;

        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Updating restore_mode to 1' -ForegroundColor Yellow};
        try{

           $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
           $SqlCommand = $sqlConnection.CreateCommand();
           $SqlConnection.Open();
           $SqlCommand.CommandText = $CommandText;        
           $SqlCommand.ExecuteNonQuery();              
        }
        catch 
        {            
            $Log.Error($file_name + ':  ' + $_.Exception)
            if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red}; 
            throw $_;   
        }

       

        #region <Backup>        
        # primary - start backup log job
        $Job_name = 'LSBackup_' + $database;
        $CommandText = 'EXEC msdb.dbo.sp_start_job @job_name = ''' + $job_name + '''';  
        $ConnectionString = $primary_connection_string;        
    
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $primary_server '-' $database ': Starting job' $Job_name -ForegroundColor Green};   
        try{
           $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
           $SqlCommand = $sqlConnection.CreateCommand();
           $SqlConnection.Open();
           $SqlCommand.CommandText = $CommandText;        
           $SqlCommand.ExecuteNonQuery();              
        }
        catch 
        {            
            $Log.Error($file_name + ':  ' + $_.Exception)
            if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red}; 
            throw $_;        
        }


        # primary - Loop untill backup log job completes        
        $ConnectionString = $primary_connection_string;
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $primary_server '-' $database ': Waiting for' $job_name 'to complete.' -ForegroundColor Green -NoNewline};                
        do{
            try
            {
               $job_status = Get-SQLAgentJobStatus -JobName $Job_name -ConnectionString $ConnectionString;           

               if ($user_interactive -eq $true) {Write-Host '.' -ForegroundColor Green -NoNewline}; # Add a dot indicating progress                
               Start-Sleep -Seconds $sleep_interval;
            }
            catch 
            {            
                $Log.Error($file_name + ':  ' + $_.Exception)
                if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red}; 
                throw $_;        
            }
        }
        while ($job_status -eq 1);    
        if ($user_interactive -eq $true) {Write-Host}
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $primary_server '-' $database ':'$Job_name 'completed' -ForegroundColor Green};                    
        #endregion


        # Pause
        $seconds = 5;
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Start sleep for' $seconds 'seconds' -ForegroundColor Yellow};             
        Start-Sleep -Seconds $seconds;


        #region <Copy>
        # secondary - start copy job
        $Job_name = 'LSCopy_' + $primary_server +'_' + $database;
        $CommandText = 'EXEC msdb.dbo.sp_start_job @job_name = ''' + $job_name +'''';  
        $ConnectionString = $secondary_connection_string; 

        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Starting job' $Job_name -ForegroundColor Yellow};             
        try{
           $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
           $SqlCommand = $sqlConnection.CreateCommand();
           $SqlConnection.Open();
           $SqlCommand.CommandText = $CommandText;        
           $SqlCommand.ExecuteNonQuery();              
        }
        catch {throw $_ };
                
        
        # secondary - wait for copy job to complete
        $ConnectionString = $secondary_connection_string;    
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $primary_server '-' $database ': Waiting for' $Job_name 'to complete.' -ForegroundColor Yellow -NoNewline};                
        do{
            try
            {
               $job_status = Get-SQLAgentJobStatus -JobName $Job_name -ConnectionString $ConnectionString;           

               if ($user_interactive -eq $true) {Write-Host '.' -ForegroundColor Yellow -NoNewline}; # Add a dot indicating progress                
               Start-Sleep -Seconds $sleep_interval;
            }
            catch 
            {            
                $Log.Error($file_name + ':  ' + $_.Exception)
                if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red}; 
                throw $_;        
            }
        }
        while ($job_status -eq 1);     
        if ($user_interactive -eq $true) {Write-Host}
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $primary_server '-' $database ':'$Job_name 'completed.' -ForegroundColor Yellow};         
        #endregion
        

        # Pause 
        $seconds = 5;
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Start sleep for' $seconds 'seconds' -ForegroundColor Yellow};             
        Start-Sleep -Seconds $seconds;


        #region <Restore>
        # secondary - start restore job
        $Job_name = 'LSRestore_' + $primary_server + '_' + $database;
        $CommandText = 'EXEC msdb.dbo.sp_start_job @job_name = ''' + $job_name +'''';  
        $ConnectionString = $secondary_connection_string;        
    
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Starting job' $Job_name -ForegroundColor Yellow};             
        try{
           $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
           $SqlCommand = $sqlConnection.CreateCommand();
           $SqlConnection.Open();
           $SqlCommand.CommandText = $CommandText;        
           $SqlCommand.ExecuteNonQuery();              
        }
        catch {throw $_ };

        Start-Sleep -Seconds $seconds

    
        # secondary - wait for restore job to complete
        $ConnectionString = $secondary_connection_string;        
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Waiting for' $Job_name 'to complete.' -ForegroundColor Yellow -NoNewline};                
        do{
            try
            {
               $job_status = Get-SQLAgentJobStatus -JobName $Job_name -ConnectionString $ConnectionString;           

               if ($user_interactive -eq $true) {Write-Host '.' -ForegroundColor Yellow -NoNewline}; # Add a dot indicating progress                
               Start-Sleep -Seconds $sleep_interval;
            }
            catch 
            {            
                $Log.Error($file_name + ':  ' + $_.Exception)
                if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red}; 
                throw $_;        
            }
        }
        while ($job_status -eq 1);     
        if ($user_interactive -eq $true) {Write-Host}
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ':'$Job_name 'completed' -ForegroundColor Yellow};   
        #endregion

        # start
        # secondary - insert history table process start
        $ConnectionString = $secondary_connection_string;
        $CommandText = 'INSERT DBA.dbo.dbcc_history (TimeStamp, MessageText, database_name) SELECT CURRENT_TIMESTAMP, ''Start'', ''' + $database +''' ;';  

        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Updating restore_mode to 0' -ForegroundColor Yellow};
        try{

           $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
           $SqlCommand = $sqlConnection.CreateCommand();
           $SqlConnection.Open();
           $SqlCommand.CommandText = $CommandText;        
           $SqlCommand.ExecuteNonQuery();              
        }
        catch 
        {            
            $Log.Error($file_name + ':  ' + $_.Exception)
            if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red}; 
            throw $_;        
        }



        #region <dbcc>
        # secondary - start dbcc        
        $CommandText = 'EXEC dbo.sp_CheckDataIntegrity @database_name = ''' + $database + ''', @no_infomsgs = 1;';
        # Modify the connection string database proprty to be the current database we work on in order to have the name loged at the table as a result of the default constraint
        $secondary_connection_string = "Server=$secondary_server;Database=$database;Integrated Security=True;Application Name=$ApplicationName;";
        $ConnectionString = $secondary_connection_string;  
    
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Starting command' $CommandText -ForegroundColor Yellow};                      
        try{
           $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
           $SqlCommand = $sqlConnection.CreateCommand();
           $SqlConnection.Open();
           $SqlCommand.CommandText = $CommandText;    
           $SqlCommand.CommandTimeout = 0;    
           $SqlCommand.ExecuteNonQuery();              
        }
        catch {                 
                $Log.Error($file_name + ':  ' + $_.Exception)
                if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_ -ForegroundColor Red}; 
                throw;
              }
        Finally 
        {
            # Revert the database to master in the connection string
            $secondary_connection_string = "Server=$secondary_server;Database=master;Integrated Security=True;Application Name=$ApplicationName;";
            $ConnectionString = $secondary_connection_string;              
        }
        #endregion
        

        
        # end
        # secondary - insert history table process end
        $ConnectionString = $secondary_connection_string;
        $CommandText = 'INSERT DBA.dbo.dbcc_history (TimeStamp, MessageText, database_name) SELECT CURRENT_TIMESTAMP, ''End'', ''' + $database +''' ;';  

        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Updating restore_mode to 0' -ForegroundColor Yellow};
        try{

           $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
           $SqlCommand = $sqlConnection.CreateCommand();
           $SqlConnection.Open();
           $SqlCommand.CommandText = $CommandText;        
           $SqlCommand.ExecuteNonQuery();              
        }
        catch 
        {            
            $Log.Error($file_name + ':  ' + $_.Exception)
            if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red}; 
            throw $_;        
        }


        <#
        # secondary - modify restore_mode back to 0 / norecovery
        $ConnectionString = $secondary_connection_string;
        $CommandText = 'UPDATE msdb.dbo.log_shipping_secondary_databases SET restore_mode = 0, disconnect_users = 1, restore_delay = 240 WHERE secondary_database = ''' + $database +'''';  

        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Updating restore_mode to 0' -ForegroundColor Yellow};
        try{

           $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
           $SqlCommand = $sqlConnection.CreateCommand();
           $SqlConnection.Open();
           $SqlCommand.CommandText = $CommandText;        
           $SqlCommand.ExecuteNonQuery();              
        }
        catch 
        {            
            $Log.Error($file_name + ':  ' + $_.Exception)
            if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red}; 
            throw $_;        
        }
        #>
    }
    catch 
    {
        # Do not throw so we can process the next database
        $Log.Error($file_name + ':  ' + $_.Exception)
        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red};     

        $subject = 'Exception at ' + $file_name;
        $body = $_.Exception;                      
        $smtp_client.Send($from, $to, $subject, $body);   
    }                  
    Finally 
    {        
        # secondary - modify restore_mode back to 0 / norecovery
        $ConnectionString = $secondary_connection_string;
        $CommandText = 'UPDATE msdb.dbo.log_shipping_secondary_databases SET restore_mode = 0, disconnect_users = 1, restore_delay = 240 WHERE secondary_database = ''' + $database +'''';  

        if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $secondary_server '-' $database ': Updating restore_mode to 0' -ForegroundColor Yellow};
        try{

           $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString);
           $SqlCommand = $sqlConnection.CreateCommand();
           $SqlConnection.Open();
           $SqlCommand.CommandText = $CommandText;        
           $SqlCommand.ExecuteNonQuery();     
           }
        catch 
        {            
            $Log.Error($file_name + ':  ' + $_.Exception)
            if ($user_interactive -eq $true) {Write-Host (Get-TimeStamp) $_.Exception -ForegroundColor Red};         
        }
    }
}

