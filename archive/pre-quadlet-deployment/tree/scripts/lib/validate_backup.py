#!/usr/bin/env python3
"""Validate an NPM backup without extracting or disclosing member content."""
import argparse
import gzip
import hashlib
import os
import pathlib
import stat
import sys
import tarfile

# These limits are intentionally conservative and may only be tightened by the
# environment (which is useful for exercising every bound in unit tests).
DEFAULT_LIMITS = {
    "archive": 10 * 1024 * 1024 * 1024,
    "manifest": 16 * 1024,
    "checksum": 512,
    "members": 100_000,
    "path": 4096,
    "member": 8 * 1024 * 1024 * 1024,
    "logical": 20 * 1024 * 1024 * 1024,
}
EXPANSION_RATIO = 200
EXPANSION_ALLOWANCE = 64 * 1024 * 1024


def limit(name):
    default = DEFAULT_LIMITS[name]
    raw = os.environ.get("BACKUP_LIMIT_" + name.upper())
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        fail()
    if value < 1:
        fail()
    return min(default, value)


def fail():
    print("INVALID_BACKUP", file=sys.stderr)
    raise SystemExit(1)


def private_regular(path, maximum):
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if (
        not stat.S_ISREG(st.st_mode)
        or stat.S_ISLNK(st.st_mode)
        or stat.S_IMODE(st.st_mode) not in (0o400, 0o600)
        or st.st_uid != os.getuid()
        or st.st_size > maximum
    ):
        return None
    return st


def bounded_read(path, maximum):
    with open(path, "rb") as source:
        value = source.read(maximum + 1)
    if len(value) > maximum:
        fail()
    return value


def scan_raw_tar(archive, archive_bytes, member_limit, path_limit, per_member_limit, logical_limit):
    """Bound expansion and extended-header allocation before tarfile parses it."""
    expanded_limit = min(
        logical_limit + 128 * 1024 * 1024,
        archive_bytes * EXPANSION_RATIO + EXPANSION_ALLOWANCE,
    )
    expanded = 0
    headers = 0

    def read_exact(source, size):
        nonlocal expanded
        chunks = []
        remaining = size
        while remaining:
            chunk = source.read(min(remaining, 1024 * 1024))
            if not chunk:
                fail()
            expanded += len(chunk)
            if expanded > expanded_limit:
                fail()
            if size <= 65536:
                chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    try:
        with gzip.open(archive, "rb") as source:
            zero_blocks = 0
            while True:
                header = source.read(512)
                if not header:
                    break
                expanded += len(header)
                if len(header) != 512 or expanded > expanded_limit:
                    fail()
                if header == b"\0" * 512:
                    zero_blocks += 1
                    if zero_blocks == 2:
                        break
                    continue
                zero_blocks = 0
                headers += 1
                if headers > member_limit * 2 + 16:
                    fail()
                try:
                    size = tarfile.nti(header[124:136])
                except (tarfile.InvalidHeaderError, ValueError):
                    fail()
                if size is None or size < 0:
                    fail()
                kind = header[156:157]
                if kind == tarfile.GNUTYPE_SPARSE:
                    fail()
                if kind in (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
                    if size > max(65536, path_limit + 1):
                        fail()
                elif size > per_member_limit:
                    fail()
                padded = ((size + 511) // 512) * 512
                read_exact(source, padded)
    except (OSError, EOFError, gzip.BadGzipFile):
        fail()


def normalized_link_target(member, target, path_limit):
    if (
        not target
        or target.startswith("/")
        or "\\" in target
        or "\x00" in target
        or len(target.encode("utf-8", "surrogateescape")) > path_limit
    ):
        fail()
    parts = list(pathlib.PurePosixPath(member).parent.parts)
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                fail()
            parts.pop()
        else:
            parts.append(part)
    if not parts or parts[0] != "letsencrypt":
        fail()
    return "/".join(parts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("--image", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--metrics", action="store_true")
    args = parser.parse_args()

    archive = os.path.abspath(args.archive)
    stem = archive[:-7] if archive.endswith(".tar.gz") else archive
    checksum = stem + ".sha256"
    external_manifest = stem + ".manifest"
    archive_limit = limit("archive")
    manifest_limit = limit("manifest")
    checksum_limit = limit("checksum")
    member_limit = limit("members")
    path_limit = limit("path")
    per_member_limit = limit("member")
    logical_limit = limit("logical")

    archive_stat = private_regular(archive, archive_limit)
    if archive_stat is None or private_regular(checksum, checksum_limit) is None or private_regular(external_manifest, manifest_limit) is None:
        fail()

    try:
        checksum_text = bounded_read(checksum, checksum_limit).decode("ascii").strip()
    except (OSError, UnicodeError):
        fail()
    parts = checksum_text.split()
    if (
        len(parts) != 2
        or parts[1] != os.path.basename(archive)
        or len(parts[0]) != 64
        or any(c not in "0123456789abcdef" for c in parts[0])
    ):
        fail()

    digest = hashlib.sha256()
    try:
        with open(archive, "rb") as source:
            remaining = archive_limit + 1
            while remaining:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                digest.update(chunk)
                remaining -= len(chunk)
            if source.read(1):
                fail()
    except OSError:
        fail()
    if parts[0] != digest.hexdigest():
        fail()

    scan_raw_tar(archive, archive_stat.st_size, member_limit, path_limit, per_member_limit, logical_limit)

    seen = set()
    roots = set()
    by_name = {}
    links = {}
    manifest_bytes = None
    member_count = 0
    logical_size = 0
    try:
        # Streaming mode avoids materializing attacker-controlled TarInfo lists.
        with tarfile.open(archive, "r|gz") as tf:
            for member in tf:
                member_count += 1
                if member_count > member_limit:
                    fail()
                raw = member.name
                if (
                    not raw
                    or raw.startswith("/")
                    or "\\" in raw
                    or "\x00" in raw
                    or len(raw.encode("utf-8", "surrogateescape")) > path_limit
                ):
                    fail()
                segments = raw[:-1].split("/") if raw.endswith("/") else raw.split("/")
                if any(value in ("", ".", "..") for value in segments):
                    fail()
                pure = pathlib.PurePosixPath(raw)
                if any(value in ("", "..") for value in pure.parts):
                    fail()
                normalized = str(pure)
                if normalized in seen:
                    fail()
                seen.add(normalized)
                if member.islnk() or member.isdev() or member.isfifo() or not (member.isdir() or member.isfile() or member.issym()):
                    fail()
                if member.type == tarfile.GNUTYPE_SPARSE or getattr(member, "sparse", None) is not None:
                    fail()
                if member.size < 0 or member.size > per_member_limit:
                    fail()
                if member.isfile():
                    logical_size += member.size
                    if logical_size > logical_limit:
                        fail()
                root = pure.parts[0]
                roots.add(root)
                if root not in ("manifest", "data", "letsencrypt"):
                    fail()
                if root == "manifest":
                    if len(pure.parts) != 1 or not member.isfile() or manifest_bytes is not None or member.size > manifest_limit:
                        fail()
                    source = tf.extractfile(member)
                    if source is None:
                        fail()
                    manifest_bytes = source.read(manifest_limit + 1)
                    if len(manifest_bytes) > manifest_limit:
                        fail()
                if member.issym():
                    if root != "letsencrypt":
                        fail()
                    links[normalized] = normalized_link_target(normalized, member.linkname, path_limit)
                    by_name[normalized] = "symlink"
                elif member.isfile():
                    by_name[normalized] = "file"
                else:
                    by_name[normalized] = "directory"
    except (OSError, tarfile.TarError, UnicodeError, ValueError):
        fail()

    if logical_size > archive_stat.st_size * EXPANSION_RATIO + EXPANSION_ALLOWANCE:
        fail()
    if roots != {"manifest", "data", "letsencrypt"} or by_name.get("data") != "directory" or by_name.get("letsencrypt") != "directory" or manifest_bytes is None:
        fail()
    # A symlink may never be an ancestor of a later extraction target.
    for name in by_name:
        parts = pathlib.PurePosixPath(name).parts
        if any("/".join(parts[:index]) in links for index in range(1, len(parts))):
            fail()
    for name, target in links.items():
        visited = {name}
        while target in links:
            if target in visited:
                fail()
            visited.add(target)
            target = links[target]
        if by_name.get(target) != "file":
            fail()

    try:
        external_bytes = bounded_read(external_manifest, manifest_limit)
        if manifest_bytes != external_bytes:
            fail()
        text = manifest_bytes.decode("utf-8")
    except (OSError, UnicodeError):
        fail()
    values = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if not separator or not key or key in values:
            fail()
        values[key] = value
    if set(values) != {"format_version", "created_utc", "image", "owner_id"}:
        fail()
    if values["format_version"] != "1" or values["image"] != args.image or values["owner_id"] != args.owner:
        fail()

    if args.metrics:
        print(f"{archive_stat.st_size} {logical_size} {member_count}")
    else:
        print("VALID_BACKUP")


if __name__ == "__main__":
    main()
