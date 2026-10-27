"""Feed only isolated fixture data to the explicitly selected Android device."""
import pathlib
import subprocess
import sys

root, serial, project = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
adb = str(pathlib.Path.home() / "Library/Android/sdk/platform-tools/adb")
base = [adb, "-s", serial]
def run(*args, **kwargs):
    return subprocess.run(base + list(args), check=True, **kwargs)

run("install", "-r", str(project / "app/build/outputs/apk/debug/app-debug.apk"))
run("install", "-r", str(project / "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"))
run("reverse", "tcp:15769", "tcp:15769")
try:
    run("shell", "run-as", "com.vdx.cliptomac", "mkdir", "-p", "cache/tls-fixture")
    for name in ("enrollment.json", "qr.png"):
        run("shell", "-T", "run-as", "com.vdx.cliptomac", "dd", f"of=cache/tls-fixture/{name}",
            input=(root / name).read_bytes(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = subprocess.run(base + ["shell", "am", "instrument", "-w", "-r", "-e", "class",
        "com.vdx.cliptomac.CredentialSecurityTest,com.vdx.cliptomac.SecurePairingDeviceTest,com.vdx.cliptomac.UploadHandoffTest",
        "com.vdx.cliptomac.test/androidx.test.runner.AndroidJUnitRunner"], capture_output=True, text=True, check=True)
    print(result.stdout)
    assert "FAILURES" not in result.stdout and "OK (" in result.stdout, "Device security tests failed"
finally:
    run("reverse", "--remove", "tcp:15769")
    run("shell", "run-as", "com.vdx.cliptomac", "rm", "-rf", "cache/tls-fixture")
