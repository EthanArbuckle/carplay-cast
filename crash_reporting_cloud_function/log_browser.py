import tarfile
from io import BytesIO
from pathlib import Path

from google.cloud import storage

CRASH_REPORT_BUCKET = "crash-reports"
GCP_PROJECT = "decoded-cove-239422"
OUTPUT = Path("crashes")

if OUTPUT.exists() is False:
    OUTPUT.mkdir()


def process_crash_report(crash_report_contents: str) -> None:
    crash_report_lines = crash_report_contents.splitlines()
    tweaks = []
    last_exc_bt = None
    dylib_occur = 0
    for idx, crash_line in enumerate(crash_report_lines):
        if "Last Exception Backtrace:" in crash_line:
            last_exc_bt = crash_report_lines[idx + 1]
        if "/Library/MobileSubstrate/DynamicLibraries/" in crash_line:
            tweaks.append(crash_line)
        if " carplayenable.dylib " in crash_line:
            dylib_occur += 1

    num_tweaks = len(tweaks)
    if num_tweaks > 40 or last_exc_bt is None or dylib_occur < 3:
        return 0
    print(f"tweaks: {num_tweaks} dylib occur {dylib_occur}\n{last_exc_bt}\n")
    for tweak in tweaks:
        print(tweak)
    print("\n\n")
    return 1


storage_client = storage.Client(project=GCP_PROJECT)
all_blobs = storage_client.list_blobs(CRASH_REPORT_BUCKET)
for blob in all_blobs:

    crash_tar_bytes = blob.download_as_bytes()
    with tarfile.open(fileobj=BytesIO(crash_tar_bytes), mode="r:*") as tarf:
        for member in tarf.getmembers():
            if member.isdir():
                continue
            file_contents = tarf.extractfile(member).read()
            if process_crash_report(file_contents.decode("utf-8")) == 1:
                shortname = Path(member.name).name
                with open(OUTPUT / shortname, mode="wb") as f:
                    f.write(file_contents)
