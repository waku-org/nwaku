# Database Migration
This tutorial explains the database migration process in nim-waku.

# Contributors Guide
## Database Migration Flow
For tracking the database version, nim-waku utilizes the built-in `user-version` variable that Sqlite provides.
The [user-version](https://github.com/status-im/nim-waku/blob/master/waku/v2/node/storage/migration/migration_types.nim) MUST be bumped up for every update on the database e.g, table schema/title change.
Each update should be accompanied by a migration script to move the content of the old version of the database to the new version.
The script MUST be added to the respective folder as explained in [Migration Folder Structure](#migration-folder-structure) with the proper naming as given in [ Migration Script Naming](#migration-file-naming). 
When connecting to the database, the  
Migration works by checking the `user_version` pragma of the database against the desired `user_version` of the application. In case that the database `user_version` is behind the most recent version, the migration will take place in which a series of migration scripts located in the folder will be executed to bring the database to the most updated version.

## Migration Folder Structure
The [migrations folder](https://github.com/status-im/nim-waku/tree/master/waku/v2/node/storage/migration) is structured as below.

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

The migration scripts are managed in two separate folders `message` and `peer`.
The `message` folder contains the migration scripts related to the message store tables.
Similarly, the `peer` folder contains the scripts relevant to the peer store tables.


## Migration File Naming
The files in [migrations folder](https://github.com/status-im/nim-waku/tree/master/waku/v2/node/storage/migration) MUST follow the following naming style in order to be properly included in the migration process. 
Files with invalid naming will not be skipped in the migration process.

`<version number>_<migration script description>.<up|down>.sql`

- `version number`: This number should match the updated value of `user-version`.
- `migration script description`: A short description of what the migration script does.
- `up|down`: One of the keywords of `up` or `down` should be selected.
  `up` stands for upgrade and `down` means downgrade.
  
### Example
A migration file with the name `00002_addTableX.up.sql` should be interpreted as: 
- `00002`:  The targeted `user-version` number.
- `addTableX`: What the script does.
- `up`: This script `upgrade`s the database from `user-version = 00001` to the `user-version = 00002`.

A downgrade migration file for `00002_addTableX.up.sql` would be e.g., `00001_removeTableX.down.sql` and should be interpreted as: 
- `00001`:  The targeted `user-version` number.
- `removeTableX`: What the script does.
- `down`: This script `downgrade`s the database from `user-version = 00002` to the `user-version = 00001`.

There can be more than one migration file for the same `user-version`. 
The migration process will consider all such files while upgrading/downgrading the database. 
Note that currently we **DO NOT** support **down migration**.

# User Guide
Migrations work out of the box. 
However, if you want to be extra sure, please take a backup of the SQLite database prior to upgrading your nim-waku version since we currently don't support downgrades of DB.
