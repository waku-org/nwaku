# Database Migration
This tutorial explains the database migration process in nim-waku.

# Contributors Guide
## Database Migration Flow
Nim-waku utilizes the built-in `user_version` variable that Sqlite provides for tracking the database versions.
The [user_version](https://github.com/status-im/nim-waku/blob/master/waku/v2/node/storage/migration/migration_types.nim) MUST be bumped up for every update on the database e.g, table schema/title change.
Each update should be accompanied by a migration script to move the content of the old version of the database to the new version.
The script MUST be added to the respective folder as explained in [Migration Folder Structure](#migration-folder-structure) with the proper naming as given in [ Migration Script Naming](#migration-file-naming). 

The migration is invoked whenever the database `user_version` is behind the target [user_version](https://github.com/status-im/nim-waku/blob/master/waku/v2/node/storage/migration/migration_types.nim) indicated in the nim-waku application.  
The respective migration scripts located in the [migrations folder](https://github.com/status-im/nim-waku/tree/master/waku/v2/node/storage/migration) will be executed to upgrade the database from its old version to the target version.

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
Files with invalid naming will be eliminated from the migration process.

`<version number>_<migration script description>.<up|down>.sql`

- `version number`: This number should match the target value of `user_version`.
- `migration script description`: A short description of what the migration script does.
- `up|down`: One of the keywords of `up` or `down` should be selected.
  `up` stands for upgrade and `down` means downgrade.
  
### Example
A migration file with the name `00002_addTableX.up.sql` should be interpreted as: 
- `00002`:  The targeted `user_version` number.
- `addTableX`: What the script does.
- `up`: This script `upgrade`s the database from `user_version = 00001` to the `user_version = 00002`.

A downgrade migration file corresponding to the `00002_addTableX.up.sql` can be e.g., `00001_removeTableX.down.sql` and should be interpreted as: 
- `00001`:  The targeted `user_version` number.
- `removeTableX`: What the script does.
- `down`: This script `downgrade`s the database from `user_version = 00002` to the `user_version = 00001`.

There can be more than one migration file for the same `user_version`. 
The migration process will consider all such files while upgrading/downgrading the database. 
Note that currently we **DO NOT** support **down migration**.

# User Guide
Migrations work out of the box. 
However, if you want to be extra sure, please take a backup of the SQLite database prior to upgrading your nim-waku version since we currently don't support downgrades of DB.
