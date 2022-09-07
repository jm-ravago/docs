# Taking a manual backup from a running db2 instance


The databases in created for namespaces on okd are configured such that you can take dumps
while the database is running. However these dumps need to be restored differently than
the dumps that can be found at http://nexus.ravago.com/images/.



## Creating the online backup

Make sure you are using intended namespace. Usually the database pod is named `db2-0`. You
need to execute the backup commands in that container and then copy the resulting file.

```
$ oc project
$ oc get pods -o custom-columns="Name:metadata.name,Image:.spec.containers[:].image" | grep -i 'db2-rav-database:'
```

```
$ oc exec -it db2-0 -- /bin/bash
root@db2-0# su - db2rav01
db2rav01@db2-0$ db2 backup database OHMDOCK online compress include logs

Backup successful. The timestamp for this backup image is : <xxxxxxxxxxxx>
```

The backup will take a minute or two, but will then spit out a success message with the
timestamp (format `YYYmmddHHMMss`) of the backup.

The generated backup file can be found in the home directory of the `db2rav01` user.  the
filename contains that timestamp printed by the export command, the name of the exported
database and the name of the user performing the action (`db2rav01` in our case).


```
db2rav01@db2-0$ ls ~/ | grep -i '<timestamp>'

OHMDOCK.0.db2rav01.DBPART000.<xxxxxxxxxxxx>.001
```

You can now copy that file to some other location

```
$ oc cp \
	db2-0:home/db2rav01/OHMDOCK.0.db2rav01.DBPART000.<xxxxxxxxxxxx>.001 \
	OHMDOCK.0.db2rav01.DBPART000.<xxxxxxxxxxxx>.001
```

Verify that the copy was successful by running `md5sum` in the docker container and on
the local copy.

```
db2rav01@db2-0$ md5sum OHMDOCK.0.db2rav01.DBPART000.<xxxxxxxxxxxx>.001
$ md5sum OHMDOCK.0.db2rav01.DBPART000.<xxxxxxxxxxxx>.001
```

---
**NOTE**

It is possible that the backup is large enough to cause issues during the copy with `oc
cp`, and that the command exists with an error.

```
Dropping out copy after 0 retries
error: unexpected EOF
```

You can circumvent this issue by splitting the larger file in chunks.

```
db2rav01@db2-0$ mkdir /tmp/split && cd /tmp/split
db2rav01@db2-0$ split -b 50MB ~/OHMDOCK.0.db2rav01.DBPART000.<xxxxxxxxxxxx>.001
$ oc cp db2-0:tmp/splitting ./splitting
$ cat ./splitting * > OHMDOCK.0.db2rav01.DBPART000.<xxxxxxxxxxxx>.001
```
---


## Turning the online backup to an offline backup

Fetch the database image used by the original database container, and start a local
instance. The image name should be `nexus.ravago.com:5000/icp/db2-rav-database`, but the
tag can change.

You can get the image name by running the command below:

```
$ oc get pods -o custom-columns="Image:.spec.containers[:].image" | grep -i 'db2-rav-database:'

nexus.ravago.com:5000/icp/db2-rav-database:24

$ docker pull nexus.ravago.com:5000/icp/db2-rav-database:24
$ docker run --name rav-db-2 --privileged nexus.ravago.com:5000/icp/db2-rav-database:24
```

Copy the database dump into the container. An alternative is to mount a volume when you
start the docker container.

```
$ docker cp OHMDOCK.0.db2rav01.DBPART000.<xxxxxxxxxxxx>.001 rav-db-2:/tmp/.
```

Run a shell in the docker container and switch to the `db2rav01` user. That user has the
`db2` tools installed and can administer the database. The backup file itself will
probably have the wrong permissions. Set the user and group to `db2rav01` while you are
still root.

```
$ docker exec -it rav-db-2 /bin/bash
root@rav-db-2# chown db2rav01:db2rav01 /tmp/OHMDOCK*
root@rav-db-2# su - db2rav01
db2rav01@rav-db-2$
```

Stop db2 and decativate the database

```
db2rav01@rav-db-2$ db2 terminate
db2rav01@rav-db-2$ db2 deactivate db OHMDOCK
```

The dump contains all transaction logs within the file. We will need to extract them such
that we can roll those forward later on.

```
db2rav01@rav-db-2$ mkdir /tmp/transaction-logs/
db2rav01@rav-db-2$ db2 restore database OHMDOCK logs from /tmp taken at <xxxxxxxxxxxx> logtarget /tmp/transaction-logs/
db2rav01@rav-db-2$ db2 restore database OHMDOCK from /tmp/ taken at <xxxxxxxxxxxx> into OHMSMALL
db2rav01@rav-db-2$ db2 rollforward database OHMSMALL to end of logs and complete overflow log path "(/tmp/transaction-logs)"
```

Then export the database again. We need to reconfigure the log archive method. If we don't
the restored database will need to be rolled forward before it can be used. However the
database startup script does not do this.

```
db2rav01@rav-db-2$ db2 update db cfg for OHMSMALL using logarchmeth1 off
db2rav01@rav-db-2$ db2 backup database OHMSMALL to /tmp/ compress

Backup successful. The timestamp for this backup image is : <yyyyyyyyyyyy>
```

The database pods start from a tar archive which contains a backup for `ohmsmall` and
optionally `ravcp`. We need to recreate such an archive where we replace the existing
backup for `ohmsmall` with the newly created backup.

```
$ curl -L -O http://nexus.ravago.com/images/<original-branch-name>/db2_base.tar
$ mkdir content && cd content
$ tar -xf ../db2_base.tar
$ rm OHMSMALL*
$ docker cp rav-db-2:/tmp/OHMSMALL.0.db2rav01.DBPART000.yyyyyyyyyyyy.001 .
$ tar -cf ../db2_base_recreated.tar
```

The new tar can then be uploaded to the nexus, either by replacing the existing
`db2_base.tar`, or by uploading it as `db2_base.tar` in a newly created directory. Keep in
mind that the file itself should always we named `db2_base.tar` (to know why have a look
at [the database startup script](https://github.com/ravago-sdc/application-containers/blob/master/dockerfiles/db2-rav-database/create_databases.sh#L34)).


more detailed reading:

- https://www.ibm.com/docs/it/license-metric-tool?topic=database-restoring-db2
- http://ohmdev/docs/docker_images/db2/
- https://www.ibm.com/docs/it/license-metric-tool?topic=database-backing-up-db2

#
