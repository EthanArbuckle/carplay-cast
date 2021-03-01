import gzip
import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

REPO_IP_ADDRESS = "206.189.219.64"
REPO_PATH = "/var/www/ghostbinrepo"
DEBS_FOLDER = "debs"


def run_local_command(command: str) -> Optional[str]:
    output = subprocess.check_output(command, shell=True)
    return output.decode("utf-8") if output else None


def run_remote_command(command: str) -> Optional[str]:
    full_command = f'ssh root@{REPO_IP_ADDRESS} "{command}"'
    return run_local_command(full_command)


def send_file(local_file: str, remote_path: str) -> None:
    run_local_command(f'scp "{local_file}" root@{REPO_IP_ADDRESS}:"{REPO_PATH}/{remote_path}"')


def run(deb_to_upload: Path) -> None:

    # Confirm connection
    try:
        if "var" not in run_remote_command("ls /"):
            raise Exception()
        # Create debs folder
        run_remote_command(f"mkdir -p {REPO_PATH}/{DEBS_FOLDER}")
    except:
        raise RuntimeError(f"Failed to connect to {REPO_IP_ADDRESS}")

    # Upload the Release file
    release_file_path = Path(__file__).parent / "Release"
    send_file(release_file_path.as_posix(), "Release")

    # Generate the Package info
    package_info = run_local_command(f"dpkg -I {deb_to_upload.as_posix()} control")

    # Generate hashes and add them to package info
    with open(deb_to_upload.as_posix(), mode="rb") as debf:
        deb_contents = debf.read()
        # Add md5
        md5_hash = hashlib.md5(deb_contents).hexdigest()
        package_info += f"MD5sum: {md5_hash}\n"
        # Add sha1
        sha1_hash = hashlib.sha1(deb_contents).hexdigest()
        package_info += f"SHA1: {sha1_hash}\n"
        # Add sha256
        sha256_hash = hashlib.sha256(deb_contents).hexdigest()
        package_info += f"SHA256: {sha256_hash}\n"

    # Add deb name to package file
    remote_deb_location = f"debs/{deb_to_upload.name}"
    package_info += f"Filename: {remote_deb_location}\n"

    # Gzip package file and upload
    with tempfile.NamedTemporaryFile(mode="wb", delete=False) as packagef, gzip.GzipFile(
        fileobj=packagef, mode="wb"
    ) as gzout:
        # Write contents to temp file
        gzout.write(package_info.encode("utf-8"))
        gzout.flush()
        gzout.close()
        packagef.close()
        # Send to server
        send_file(packagef.name, "Packages.gz")
        os.remove(packagef.name)

    # Upload deb
    send_file(deb_to_upload.as_posix(), remote_deb_location)

    print("done")


if __name__ == "__main__":

    if len(sys.argv) < 2 or ".deb" not in sys.argv[1]:
        raise Exception("No deb provided")

    provided_deb = Path(sys.argv[1])
    run(provided_deb)
