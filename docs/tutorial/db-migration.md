# Database Migration
This tutorial explains the database migration in nim-waku. As of now, migrations should work out of the box, however if you want to be extra sure take a backup of SQLite DB first since we currently don't support downgrades of DB.


Migration works by checking the `user_version` pragma of the database against the desired `user_version` of the application. In case that the database `user_version` is behind the most recent version, the migration will take place in which a series of migration scripts located in the folder will be executed to bring the database to the most updated version.

The migrations folder structure looks like below.  The `message` folder contains migration scripts for the tables that are related to the message store whereas the`peer` folder contains the scripts

```
|-- migration
|  |--migration_scripts
|  |  |--message
|  |  |  |--00001_basicMessageTable.up.sql
|  |  |  |--00002_addSenderTimeStamp.up
|  |  |  |-- ...
|  |  |--peer
|  |  |  |--00001_basicPeerTable.up.sql
|  |  |  |-- ...
```

The files in this folder follow the following naming convention:

`<version number>_<migration script description>.<up|down>.sql`

- version number: This number should match the current user_version of the database
- migration script description: the short description of what the migration script does
- up|down: One of the keywords of `up` or `down` should be selcted where `up` indicates that the migration file contains script to upgrade from the prior user_version to the provided user_version and `down` means the script will downgrade the database from the higher user_version to the provided user_version. 
  
Example:

`00002_addSenderTimeStamp.up.sql`
- `00002`:  indicates the user_version
- `addSenderTimeStamp` briefly describes the outcome of this script
- `up` signifies that this script upgrades the database from version 1 to version 2
