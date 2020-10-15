USE [master];
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;
GO
/*
	Yaniv Etrogi 20130120
	Use the syntax of INSERT..EXEC in order to execute DBCC CHECKDB WITH TABLERESULTS and log the output to table DBA.dbo.DBCC_History
*/
CREATE PROCEDURE [dbo].[sp_CheckDataIntegrity]
(
	 @database_name sysname = NULL
	,@no_infomsgs bit = 1
)
AS
SET NOCOUNT ON; 
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;


IF OBJECT_ID('tempdb.dbo.#data', 'U') IS NOT NULL DROP TABLE dbo.#data;
CREATE TABLE dbo.#data(id int IDENTITY(1,1) PRIMARY KEY CLUSTERED, [database] sysname NULL, size_mb bigint NULL);

-- Single database
IF @database_name IS NOT NULL
BEGIN;
	INSERT #data ([database], size_mb)
	SELECT 
		 d.name 
		,f.size_mb
	FROM sys.databases d
	INNER JOIN 
		(
			SELECT 
				 database_id
				,SUM(size)/128 size_mb 
			FROM sys.master_files  
			GROUP BY database_id
		) f ON f.database_id = d.database_id
	WHERE d.state_desc IN ('ONLINE', 'RESTORING')
	AND d.name = @database_name
END;

-- All databaseses
	ELSE
BEGIN;
	INSERT #data ([database], size_mb)
	SELECT 
		 d.name 
		,f.size_mb
	FROM sys.databases d
	INNER JOIN 
		(
			SELECT 
				 database_id
				,SUM(size)/128 size_mb 
			FROM sys.master_files  
			GROUP BY database_id
		) f ON f.database_id = d.database_id
	WHERE d.state_desc IN ('ONLINE', 'RESTORING')
	AND d.name NOT LIKE '%test%'
	AND d.name NOT IN (N'tempdb')
	AND d.source_database_id IS NULL
	ORDER BY d.name;
END;


DECLARE @command varchar(max), @database sysname, @min_id int, @max_id int;
SELECT  @min_id = 1, @max_id = (SELECT MAX(id) FROM dbo.#data);

WHILE @min_id <= @max_id
BEGIN;
	SELECT @database = [database] FROM dbo.#data WHERE id = @min_id;

	SELECT @command = 'USE [' + @database + ']; DBCC CHECKDB(''' + @database + ''') WITH TABLERESULTS ' + CASE WHEN @no_infomsgs = 1 THEN ',NO_INFOMSGS' ELSE '' END + ''

    PRINT '-- ' + @command;
    INSERT DBA.dbo.DBCC_History ([Error], [Level], [State], [MessageText], [RepairLevel], [Status], [DbId], [DbFragId], [ObjectId], [IndexId], [PartitionID], [AllocUnitID], [RidDbId], [RidPruId], [File], [Page], [Slot], [RefDbId], [RefPruId], [RefFile], [RefPage], [RefSlot], [Allocation] )
    EXEC (@command);

	SELECT @min_id += 1;
END;
GO

USE master; EXEC sp_MS_marksystemobject 'sp_CheckDataIntegrity';

