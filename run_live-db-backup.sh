#! /usr/bin/env sh

function list_incomplete_files () {
	diff -u "${@}" \
		| grep -i '^\(-\|^+\)[0-9a-f]\+' \
		| awk '{ print $2 }' \
		| sort -u
}

count=$(oc exec db2-0 -- /usr/bin/ls /home/db2rav01 | grep '^OHMDOCK\.' | wc -l)
if [ "${count}" -gt 0 ]; then
	echo "[ERROR]" >&2;
	echo "    Backupfile already exists on target." >&2;
	exit 1
fi

oc exec -i db2-0 -- /usr/bin/sh -c 'su - db2rav01' <<-EOF
	db2 backup database OHMDOCK online compress include logs
EOF

file=$(oc exec db2-0 -- /usr/bin/ls /home/db2rav01 | grep '^OHMDOCK\.')

oc exec -i db2-0 -- /usr/bin/sh -c 'su - db2rav01' <<-EOF
	mkdir -p /tmp/split
	cd /tmp/split
	split -b 50MB "/home/db2rav01/${file}"
EOF

oc exec db2-0 -- /usr/bin/sh -c "md5sum /tmp/split/*" | sed -e 's/\/tmp\/split\///' > 1.txt
oc exec db2-0 -- /usr/bin/md5sum /home/db2rav01/"${file}" > 1-full.txt

oc cp db2-0:tmp/split ./split
md5sum ./split/* | sed -e 's/\.\/split\///' > 2.txt

while [ "$(list_incomplete_files 1.txt 2.txt | wc -l)" -gt 0 ]; do
	list_incomplete_files 1.txt 2.txt | while read chunk; do
		echo "retrying line '${chunk}' ..."
		oc cp "db2-0:tmp/split/${chunk}" "./split/${chunk}"
	done
	md5sum ./split/* | sed -e 's/\.\/split\///' > 2.txt
done

oc exec -i db2-0 -- /usr/bin/sh -c 'su - db2rav01' <<-EOF
	rm -r "/tmp/split" "/home/db2rav01/${file}"
EOF

cat ./split/* > ./"${file}"
md5sum "${file}" > 2-full.txt
