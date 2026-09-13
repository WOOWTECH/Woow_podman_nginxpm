#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source "$ROOT/tests/testlib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pin='docker.io/jc21/nginx-proxy-manager:2.15.1@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb'; owner=$(printf a%.0s {1..64})
mkdir "$TMP/tree"; mkdir "$TMP/tree/data" "$TMP/tree/letsencrypt"; printf 'format_version=1\ncreated_utc=20260827T000000Z\nimage=%s\nowner_id=%s\n' "$pin" "$owner" >"$TMP/tree/manifest"
make_set() {
  local name=$1
  tar -C "$TMP/tree" -czf "$TMP/$name.tar.gz" manifest data letsencrypt
  cp "$TMP/tree/manifest" "$TMP/$name.manifest"
  chmod 600 "$TMP/$name.tar.gz" "$TMP/$name.manifest"
  (cd "$TMP" && sha256sum "$name.tar.gz" >"$name.sha256")
  chmod 600 "$TMP/$name.sha256"
}
make_set valid
assert_success 'valid same-owner backup set accepted' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/valid.tar.gz" --image "$pin" --owner "$owner"
printf x >>"$TMP/valid.tar.gz"; assert_failure 'checksum mismatch rejected' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/valid.tar.gz" --image "$pin" --owner "$owner"
mkdir -p "$TMP/tree/letsencrypt/archive/example.test" "$TMP/tree/letsencrypt/live/example.test"
printf certificate >"$TMP/tree/letsencrypt/archive/example.test/fullchain1.pem"
ln -s ../../archive/example.test/fullchain1.pem "$TMP/tree/letsencrypt/live/example.test/fullchain.pem"
make_set letsencrypt-links
assert_success 'real letsencrypt relative certificate symlink accepted' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/letsencrypt-links.tar.gz" --image "$pin" --owner "$owner"
rm "$TMP/tree/letsencrypt/live/example.test/fullchain.pem"; ln -s /etc/passwd "$TMP/tree/letsencrypt/live/example.test/fullchain.pem"
make_set absolute-link
assert_failure 'absolute certificate symlink rejected' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/absolute-link.tar.gz" --image "$pin" --owner "$owner"
rm "$TMP/tree/letsencrypt/live/example.test/fullchain.pem"; ln -s ../../../../escape "$TMP/tree/letsencrypt/live/example.test/fullchain.pem"
make_set escaping-link
assert_failure 'escaping certificate symlink rejected' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/escaping-link.tar.gz" --image "$pin" --owner "$owner"
rm "$TMP/tree/letsencrypt/live/example.test/fullchain.pem"; ln -s ../../archive/example.test/missing.pem "$TMP/tree/letsencrypt/live/example.test/fullchain.pem"
make_set dangling-link
assert_failure 'dangling certificate symlink rejected' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/dangling-link.tar.gz" --image "$pin" --owner "$owner"
rm "$TMP/tree/letsencrypt/live/example.test/fullchain.pem"
make_set foreign
assert_failure 'foreign owner rejected' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/foreign.tar.gz" --image "$pin" --owner "$(printf b%.0s {1..64})"
printf altered >>"$TMP/foreign.manifest"
assert_failure 'external manifest mismatch rejected' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/foreign.tar.gz" --image "$pin" --owner "$owner"
cp "$TMP/tree/manifest" "$TMP/foreign.manifest"; chmod 600 "$TMP/foreign.manifest"
python3 - "$TMP" <<'PY'
import io,os,tarfile,sys
root=sys.argv[1]
manifest=open(root+'/tree/manifest','rb').read()
for kind,name in [('traversal','data/../escape'),('hardlink','data/hard'),('duplicate','data/file')]:
 path=f'{root}/{kind}.tar.gz'
 with tarfile.open(path,'w:gz') as t:
  for d in ('data','letsencrypt'):
   x=tarfile.TarInfo(d); x.type=tarfile.DIRTYPE; t.addfile(x)
  x=tarfile.TarInfo('manifest'); x.size=len(manifest); t.addfile(x,io.BytesIO(manifest))
  x=tarfile.TarInfo(name)
  if kind=='hardlink': x.type=tarfile.LNKTYPE; x.linkname='manifest'; t.addfile(x)
  else:
   x.size=1; t.addfile(x,io.BytesIO(b'x'))
   if kind=='duplicate': t.addfile(x,io.BytesIO(b'y'))
 os.chmod(path,0o600)
 open(f'{root}/{kind}.manifest','wb').write(manifest); os.chmod(f'{root}/{kind}.manifest',0o600)
 os.system(f'cd {root} && sha256sum {kind}.tar.gz > {kind}.sha256 && chmod 600 {kind}.sha256')
PY
for kind in traversal hardlink duplicate; do assert_failure "$kind archive rejected" python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/$kind.tar.gz" --image "$pin" --owner "$owner"; done
chmod 644 "$TMP/foreign.tar.gz"; assert_failure 'non-private archive rejected' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/foreign.tar.gz" --image "$pin" --owner "$owner"

# Tightened limits exercise the same fail-closed production bounds without
# constructing multi-gigabyte fixtures.
make_set bounded
assert_failure 'archive byte bound is enforced before hashing' env BACKUP_LIMIT_ARCHIVE=32 python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/bounded.tar.gz" --image "$pin" --owner "$owner"
assert_failure 'checksum sidecar byte bound is enforced' env BACKUP_LIMIT_CHECKSUM=16 python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/bounded.tar.gz" --image "$pin" --owner "$owner"
assert_failure 'manifest sidecar byte bound is enforced' env BACKUP_LIMIT_MANIFEST=32 python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/bounded.tar.gz" --image "$pin" --owner "$owner"
assert_failure 'streamed member count bound is enforced' env BACKUP_LIMIT_MEMBERS=2 python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/bounded.tar.gz" --image "$pin" --owner "$owner"
assert_failure 'member path byte bound is enforced' env BACKUP_LIMIT_PATH=7 python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/bounded.tar.gz" --image "$pin" --owner "$owner"
assert_failure 'per-member logical size bound is enforced' env BACKUP_LIMIT_MEMBER=32 python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/bounded.tar.gz" --image "$pin" --owner "$owner"
assert_failure 'cumulative logical size bound is enforced' env BACKUP_LIMIT_LOGICAL=64 python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/bounded.tar.gz" --image "$pin" --owner "$owner"
metrics=$(python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/bounded.tar.gz" --image "$pin" --owner "$owner" --metrics)
[[ $metrics =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] && ok 'validated metrics expose bounded staging requirements' || not_ok 'validated metrics expose bounded staging requirements'

cp -a "$TMP/tree" "$TMP/sparse-tree"
truncate -s 1048576 "$TMP/sparse-tree/data/sparse"
tar --sparse --format=gnu -C "$TMP/sparse-tree" -czf "$TMP/sparse.tar.gz" manifest data letsencrypt
cp "$TMP/tree/manifest" "$TMP/sparse.manifest"; chmod 600 "$TMP/sparse.tar.gz" "$TMP/sparse.manifest"
(cd "$TMP" && sha256sum sparse.tar.gz >sparse.sha256); chmod 600 "$TMP/sparse.sha256"
assert_failure 'GNU sparse member is rejected as a resource bomb' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/sparse.tar.gz" --image "$pin" --owner "$owner"

python3 - "$TMP" <<'PY'
import hashlib,io,os,tarfile,sys
root=sys.argv[1]; manifest=open(root+'/tree/manifest','rb').read(); name='symlink-parent'
with tarfile.open(f'{root}/{name}.tar.gz','w:gz') as t:
 for d in ('data','letsencrypt'):
  x=tarfile.TarInfo(d); x.type=tarfile.DIRTYPE; t.addfile(x)
 x=tarfile.TarInfo('manifest'); x.size=len(manifest); t.addfile(x,io.BytesIO(manifest))
 x=tarfile.TarInfo('letsencrypt/target'); x.size=1; t.addfile(x,io.BytesIO(b'x'))
 x=tarfile.TarInfo('letsencrypt/link'); x.type=tarfile.SYMTYPE; x.linkname='target'; t.addfile(x)
 x=tarfile.TarInfo('letsencrypt/link/child'); x.size=1; t.addfile(x,io.BytesIO(b'x'))
open(f'{root}/{name}.manifest','wb').write(manifest)
for suffix in ('tar.gz','manifest'): os.chmod(f'{root}/{name}.{suffix}',0o600)
digest=hashlib.sha256(open(f'{root}/{name}.tar.gz','rb').read()).hexdigest()
open(f'{root}/{name}.sha256','w').write(f'{digest}  {name}.tar.gz\n'); os.chmod(f'{root}/{name}.sha256',0o600)
PY
assert_failure 'symlink ancestor extraction pivot is rejected' python3 "$ROOT/scripts/lib/validate_backup.py" "$TMP/symlink-parent.tar.gz" --image "$pin" --owner "$owner"
finish
