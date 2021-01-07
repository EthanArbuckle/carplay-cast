import io
import tarfile
import uuid

from google.cloud import storage

CRASH_REPORT_BUCKET = "crash-reports"
GCP_PROJECT = "decoded-cove-239422"


def find_value_for_key(key: bytes, contents: bytes) -> str:
    for content_line in contents.split(b"\n"):
        if key in content_line:
            value = content_line.replace(key, b"").strip()
            value = value.replace(b" ", b"-")
            return value.decode("utf-8")
    return None


def process_crash_reports(request):
    """Responds to any HTTP request.
    Args:
        request (flask.Request): HTTP request object.
    Returns:
        The response text or any set of values that can be turned into a
        Response object using
        `make_response <http://flask.pocoo.org/docs/1.0/api/#flask.Flask.make_response>`.
    """
    try:
        # Create an in-memory file to represent the tar bytes
        request_data = request.get_data()
        tarfileobj = io.BytesIO(request_data)

        # Open the tarfile and look for some identifying information
        hardware_model = None
        os_version = None
        number_of_crashes = 0
        cr4shed = False

        with tarfile.open(fileobj=tarfileobj, mode="r:gz") as tar:
            number_of_crashes = len(tar.getmembers())
            for item in tar.getmembers():
                # Skip dirs
                if item.isdir():
                    continue
                # Extract the file contents
                contents = tar.extractfile(item.name).read()
                # Look for hardware and OS info
                hardware_model = find_value_for_key(b"Hardware Model:", contents)
                os_version = find_value_for_key(b"OS Version:", contents)

                # Cr4shed format
                device_infos = find_value_for_key(b"Device: ", contents)

                if device_infos:
                    hardware_model, os_version = device_infos.split(",-")
                    cr4shed = True

                if hardware_model and os_version:
                    break

        hardware_model = hardware_model or "unknown_hw"
        os_version = os_version or "unknown_os"

        print(f"saving {number_of_crashes} crashlogs from {hardware_model} {os_version}")
        storage_client = storage.Client(project=GCP_PROJECT)
        bucket = storage_client.get_bucket(CRASH_REPORT_BUCKET)

        marker = "cr4shes" if cr4shed else "crashes"
        filename = f"{uuid.uuid1()}_{number_of_crashes}{marker}.tar.gz"
        crash_report_save_path = f"{os_version}/{hardware_model}/{filename}"
        blob = bucket.blob(crash_report_save_path)

        # Perform upload
        tarfileobj.seek(0)
        blob.upload_from_file(file_obj=tarfileobj)

        return b"Ok"
    except Exception as exc:
        print(f"failed to handle request: {exc}")
        return b"error"
