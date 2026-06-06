import subprocess
import json
import sys

bucket = "eks-production-stack-db-backups"

def run_cmd(cmd):
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return result.stdout, result.stderr

print("Listing all object versions and delete markers from bucket:", bucket)
out, err = run_cmd(["aws", "s3api", "list-object-versions", "--bucket", bucket])

if err:
    print("Error listing versions:", err)
    # If bucket is already gone or access is denied
    sys.exit(0)

if not out.strip():
    print("Bucket is empty or does not exist.")
    sys.exit(0)

try:
    data = json.loads(out)
except Exception as e:
    print(f"Failed to parse JSON: {e}")
    sys.exit(1)

objects_to_delete = []

if "Versions" in data and data["Versions"]:
    for v in data["Versions"]:
        objects_to_delete.append({"Key": v["Key"], "VersionId": v["VersionId"]})

if "DeleteMarkers" in data and data["DeleteMarkers"]:
    for dm in data["DeleteMarkers"]:
        objects_to_delete.append({"Key": dm["Key"], "VersionId": dm["VersionId"]})

if not objects_to_delete:
    print("No versions or delete markers to delete.")
    sys.exit(0)

print(f"Found {len(objects_to_delete)} items to delete.")

# Delete in batches of 1000
for i in range(0, len(objects_to_delete), 1000):
    batch = objects_to_delete[i:i+1000]
    payload = {"Objects": batch, "Quiet": True}
    payload_str = json.dumps(payload)
    print(f"Deleting batch of {len(batch)} objects...")
    
    # Run the delete command
    res_out, res_err = run_cmd(["aws", "s3api", "delete-objects", "--bucket", bucket, "--delete", payload_str])
    if res_err:
        print("Error during deletion:", res_err)
    else:
        print("Batch deleted successfully.")
