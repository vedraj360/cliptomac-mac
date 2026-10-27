"""Isolated real TLS integration: never connects to the user's live ClipToMac service."""
import concurrent.futures
import hashlib
import http.client
import json
import pathlib
import socket
import ssl
import sys
import time

root = pathlib.Path(sys.argv[1])
for _ in range(200):
    if (root / "ready").exists():
        break
    time.sleep(.1)
else:
    raise RuntimeError("TLS fixture did not start: " + (root / "server.log").read_text())
enrollment = json.loads((root / "enrollment.json").read_text())
certificate = (root / "certificate.der").read_bytes()
assert hashlib.sha256(certificate).hexdigest() == enrollment["fingerprint"]
context = ssl.create_default_context(cafile=str(root / "certificate.pem"))
# This fixture's self-signed leaf is the sole trust anchor. Its exact pin is checked before sending.
context.check_hostname = False
context.minimum_version = ssl.TLSVersion.TLSv1_2

def request(method, path, body=None, token=None, headers=None):
    connection = http.client.HTTPSConnection("127.0.0.1", 15769, context=context, timeout=15)
    connection.connect()
    assert hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest() == enrollment["fingerprint"]
    fields = dict(headers or {})
    if token:
        fields["X-ClipToMac-Token"] = token
    if isinstance(body, dict):
        body = json.dumps(body).encode()
        fields["Content-Type"] = "application/json"
    connection.request(method, path, body=body, headers=fields)
    response = connection.getresponse()
    data = response.read()
    status = response.status
    connection.close()
    return status, json.loads(data) if data else {}

assert request("GET", "/ping")[1]["securityProtocol"] == 3
assert request("GET", "/inbox", token="legacy-token")[0] == 401
assert request("GET", "/inbox")[0] == 401
assert request("GET", "/ping", headers={"Origin": "https://untrusted.invalid"})[0] == 403
pair = {"deviceId": "android-1234567890abcdef", "deviceName": "Fixture phone", "code": "123456", "protocolVersion": 3, "nonce": "wrong"}
assert request("POST", "/pair/request", pair)[0] == 403
pair["nonce"] = enrollment["nonce"]
status, result = request("POST", "/pair/request", pair)
assert status == 200 and result["securityProtocol"] == 3
token = result["token"]
assert request("POST", "/pair/request", pair)[0] == 403, "Enrollment nonce was replayable"
assert request("GET", "/inbox", token=token)[0] == 200

payload = bytes(range(251)) * 66000  # Two parallel buckets, with a partial final bucket.
manifest = {"protocolVersion": 2, "transferId": "secure-fixture", "size": len(payload), "bucketSize": 4 * 1024 * 1024,
            "sha256": hashlib.sha256(payload).hexdigest(), "kind": "file", "mimeType": "application/octet-stream",
            "name": "fixture.bin", "app": "Fixture", "package": "fixture", "timestamp": 0}
assert request("POST", "/buckets/start", manifest, token)[0] == 200
def send(index):
    bucket = payload[index * manifest["bucketSize"]:(index + 1) * manifest["bucketSize"]]
    return request("PUT", f"/buckets/secure-fixture/{index}", bucket, token, {"X-Bucket-SHA256": hashlib.sha256(bucket).hexdigest()})[0]
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
    assert list(workers.map(send, range((len(payload) + manifest["bucketSize"] - 1) // manifest["bucketSize"]))) == [200] * ((len(payload) + manifest["bucketSize"] - 1) // manifest["bucketSize"])
assert request("POST", "/buckets/secure-fixture/complete", {}, token)[0] == 200
assert request("POST", "/buckets/secure-fixture/complete", {}, token)[0] == 200
assert request("POST", "/pair/unpair", {}, token)[0] == 200
assert request("GET", "/inbox", token=token)[0] == 401, "Revoked credential was accepted"

try:
    plain = socket.create_connection(("127.0.0.1", 15769), timeout=3)
    plain.sendall(b"GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert not plain.recv(1024).startswith(b"HTTP/"), "Plain HTTP was accepted"
except (ConnectionError, TimeoutError):
    pass
finally:
    plain.close()

# A normal public-CA client must reject this un-enrolled self-signed identity.
try:
    untrusted = http.client.HTTPSConnection("127.0.0.1", 15769, timeout=5)
    untrusted.connect()
except ssl.SSLCertVerificationError:
    pass
else:
    raise AssertionError("Untrusted certificate was accepted")
print("PASS real TLS: certificate, pin, encrypted parallel buckets, verified one-use enrollment, browser rejection, legacy-token rejection, revocation, no HTTP fallback")
