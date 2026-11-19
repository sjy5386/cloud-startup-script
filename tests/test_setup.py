"""Run only inside a disposable root container; the fixtures replace /etc/netplan.

docker build -t cloud-startup-tests -f tests/Dockerfile .
docker run --rm --network none -v "$PWD:/review:ro" cloud-startup-tests

Netplan merging and generation are real. systemctl and netplan apply are stubbed;
these tests do not exercise a running systemd instance or DHCP/RA traffic.
"""

import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "setup.sh").read_text()
DNS_FUNCTIONS = SOURCE[
    SOURCE.index("netplan_dns_ready=0") : SOURCE.index("\nglobal_dns_is_exact() {")
]
APPLY_DNS = SOURCE[
    SOURCE.index("apply_pinned_dns() {") : SOURCE.index("\n# Every resolver")
]
VERIFY_DNS = SOURCE[
    SOURCE.index("\ndns_is_exact() {") + 1 : SOURCE.index("\napply_pinned_dns\n")
]
APPLY_SSH = SOURCE[
    SOURCE.index("apply_ssh_hardening() {") : SOURCE.index("\napply_ssh_hardening\n")
]
PRELUDE = """set -euo pipefail
log() { printf '[setup] %s\\n' "$*" >&2; }
err() { printf '[setup][error] %s\\n' "$*" >&2; exit 1; }
dns_list=(1.1.1.1 1.0.0.1)
"""
IN_CONTAINER = Path("/.dockerenv").exists() and os.geteuid() == 0


@unittest.skipUnless(IN_CONTAINER, "requires a disposable root Docker container")
class NetplanTests(unittest.TestCase):
    def setUp(self):
        import yaml

        self.yaml = yaml
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.backup_marker = Path(self.temp.name) / "backup-path"
        # Netplan 1.2 propagates daemon-reload errors. Generate real backend
        # files while simulating only this call in the non-systemd container.
        bindir = Path(self.temp.name) / "bin"
        bindir.mkdir()
        systemctl = bindir / "systemctl"
        systemctl.write_text("""#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = daemon-reload ] && [ "$2" = --no-ask-password ]; then
  exit 0
fi
printf 'Unexpected systemctl call in Netplan test: %s\\n' "$*" >&2
exit 99
""")
        systemctl.chmod(0o700)
        self.env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}"}
        for directory in ("/etc/netplan", "/run/netplan", "/lib/netplan"):
            path = Path(directory)
            if path.exists():
                shutil.rmtree(path)
            path.mkdir(parents=True)
        self.original = Path("/etc/netplan/50-cloud-init.yaml")
        self.override = Path("/etc/netplan/99-dns.yaml")
        self.write(self.original, {"network": {"version": 2, "ethernets": {"eth0": {"dhcp4": True}}}})

    def write(self, path, data):
        path.write_text(self.yaml.safe_dump(data, sort_keys=False))
        path.chmod(0o600)

    def static_config(self):
        data = self.yaml.safe_load(self.original.read_text())
        cfg = data["network"]["ethernets"]["eth0"]
        cfg["addresses"] = ["192.0.2.2/24"]
        cfg["routes"] = [{"to": "default", "via": "192.0.2.1"}]
        cfg["nameservers"] = {"addresses": ["10.0.0.2"], "search": ["example.test"]}
        self.write(self.original, data)
        self.original.chmod(0o640)
        os.chown(self.original, 123, 456)
        self.original.write_text("# original comment\n" + self.original.read_text())
        return data

    def run_pin(self, stubs="", after=""):
        marker = shlex.quote(str(self.backup_marker))
        script = PRELUDE + DNS_FUNCTIONS + APPLY_DNS + VERIFY_DNS + "\n" + stubs + "\n"
        script += "pin_dns_via_netplan\n"
        script += f"printf '%s' \"$netplan_backup_dir\" > {marker}\n"
        script += "[ \"$netplan_dns_ready\" -eq 1 ]\n" + after
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=self.env)

    def merged(self):
        result = subprocess.run(["netplan", "get"], capture_output=True, text=True, check=True, env=self.env)
        return self.yaml.safe_load(result.stdout)["network"]

    def assert_restored(self, result, original, override=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.original.read_bytes(), original)
        if override is None:
            self.assertFalse(self.override.exists())
        else:
            self.assertEqual(self.override.read_bytes(), override)

    def tearDown(self):
        # Failure tests intentionally retain backups for diagnostics.
        for path in Path("/var/tmp").glob("cloud-startup-netplan.*"):
            shutil.rmtree(path)

    def test_dhcp_only_keeps_source_unchanged(self):
        original = self.original.read_bytes()
        result = self.run_pin()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.original.read_bytes(), original)
        cfg = self.merged()["ethernets"]["eth0"]
        self.assertEqual(set(cfg["nameservers"]["addresses"]), {"1.1.1.1", "1.0.0.1"})
        self.assertFalse(cfg["dhcp4-overrides"]["use-dns"])
        self.assertEqual(self.override.stat().st_mode & 0o777, 0o600)

    def test_static_dns_replaced_without_changing_routes_or_search(self):
        original = self.static_config()["network"]["ethernets"]["eth0"]
        result = self.run_pin()
        self.assertEqual(result.returncode, 0, result.stderr)
        cfg = self.merged()["ethernets"]["eth0"]
        self.assertEqual(set(cfg["nameservers"]["addresses"]), {"1.1.1.1", "1.0.0.1"})
        for key in ("addresses", "routes", "dhcp4"):
            self.assertEqual(cfg[key], original[key])
        self.assertEqual(cfg["nameservers"]["search"], ["example.test"])
        metadata = self.original.stat()
        self.assertEqual((metadata.st_uid, metadata.st_gid, metadata.st_mode & 0o777), (123, 456, 0o640))
        backend = "\n".join(path.read_text() for path in Path("/run/systemd/network").glob("*.network"))
        self.assertNotIn("DNS=10.0.0.2", backend)
        self.assertIn("DNS=1.1.1.1", backend)

    def test_static_dns_in_multiple_fragments_and_interfaces(self):
        self.static_config()
        self.write(Path("/etc/netplan/60-extra.yaml"), {
            "network": {"version": 2, "ethernets": {
                "eth0": {"nameservers": {"addresses": ["10.0.0.3"]}},
                "eth1": {"dhcp4": True, "dhcp6": True, "nameservers": {"addresses": ["10.0.0.4"]}},
            }}
        })
        result = self.run_pin()
        self.assertEqual(result.returncode, 0, result.stderr)
        for cfg in self.merged()["ethernets"].values():
            self.assertEqual(set(cfg["nameservers"]["addresses"]), {"1.1.1.1", "1.0.0.1"})
        self.assertFalse(self.merged()["ethernets"]["eth1"]["dhcp6-overrides"]["use-dns"])

    def test_generate_failure_restores_previous_override_and_original_bytes(self):
        self.static_config()
        self.override.write_text("# previous override\nnetwork:\n  version: 2\n")
        self.override.chmod(0o600)
        original, override = self.original.read_bytes(), self.override.read_bytes()
        result = self.run_pin(stubs="""
netplan() {
  if [ "$1" = generate ] && grep -q '^# managed by cloud-startup-script' /etc/netplan/99-dns.yaml; then
    return 42
  fi
  /usr/sbin/netplan "$@"
}
""")
        self.assert_restored(result, original, override)
        self.assertIn("restored original files", result.stderr)
        metadata = self.original.stat()
        self.assertEqual((metadata.st_uid, metadata.st_gid, metadata.st_mode & 0o777), (123, 456, 0o640))

    def test_merged_mismatch_from_run_shadow_is_detected_and_restored(self):
        self.static_config()
        original = self.original.read_bytes()
        self.write(Path("/run/netplan/99-dns.yaml"), {
            "network": {"version": 2, "ethernets": {"eth0": {"nameservers": {"addresses": ["9.9.9.9"]}}}}
        })
        result = self.run_pin()
        self.assert_restored(result, original)
        self.assertIn("netplan DNS mismatch", result.stderr)

    def test_writer_failure_after_changes_restores_original(self):
        self.static_config()
        original = self.original.read_bytes()
        result = self.run_pin(stubs='python3() { /usr/bin/python3 "$@" || return; return 7; }')
        self.assert_restored(result, original)
        self.assertIn("netplan write failed", result.stderr)

    def test_apply_failure_restores_configuration_before_retry(self):
        self.static_config()
        original = self.original.read_bytes()
        counter = shlex.quote(str(Path(self.temp.name) / "apply-count"))
        stubs = """
netplan() {
  if [ "$1" = apply ]; then
    if [ ! -f COUNTER ]; then touch COUNTER; return 1; fi
    grep -q '10.0.0.2' /etc/netplan/50-cloud-init.yaml
    return
  fi
  /usr/sbin/netplan "$@"
}
systemctl() { return 0; }
""".replace("COUNTER", counter)
        result = self.run_pin(stubs=stubs, after="apply_pinned_dns\n")
        self.assert_restored(result, original)
        self.assertIn("restored original files", result.stderr)

    def test_successful_apply_removes_backup(self):
        result = self.run_pin(
            stubs="""
netplan() { [ "$1" = apply ] || /usr/sbin/netplan "$@"; }
systemctl() { return 0; }
retry() { "$@"; }
resolvectl() { printf '%s\\n' 'Global: 1.1.1.1 1.0.0.1'; }
""",
            after='apply_pinned_dns\nverify_pinned_dns\n[ -z "$netplan_backup_dir" ]\n',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.backup_marker.read_text()).exists())

    def test_runtime_dns_verification_failure_restores_original(self):
        self.static_config()
        original = self.original.read_bytes()
        result = self.run_pin(stubs="""
netplan() { [ "$1" = apply ] || /usr/sbin/netplan "$@"; }
systemctl() { return 0; }
retry() { "$@"; }
resolvectl() { printf '%s\\n' 'Global: 1.1.1.1 1.0.0.1' 'Link 2 (eth0): 10.0.0.2'; }
""", after="apply_pinned_dns\nverify_pinned_dns\n")
        self.assert_restored(result, original)
        self.assertIn("DNS verification failed", result.stderr)

    def test_missing_config_directory_keeps_skip_behavior(self):
        shutil.rmtree("/etc/netplan")
        script = PRELUDE + DNS_FUNCTIONS + '\npin_dns_via_netplan\n[ "$netplan_dns_ready" -eq 0 ]\n'
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)


class SshTests(unittest.TestCase):
    def run_apply(self, state="active", reload_ok=True, socket_ok=True, service_ok=True, show_ok=True, port="22"):
        with tempfile.TemporaryDirectory() as directory:
            calls = Path(directory) / "calls"
            stubs = """
systemctl() {
  printf '%s\\n' "$*" >> CALLS
  case "$1" in
    show) SHOW_OK || return 1; printf '%s\\n' STATE ;;
    reload) RELOAD_OK ;;
    is-active)
      if [ "$3" = ssh.socket ]; then SOCKET_OK; else SERVICE_OK; fi
      ;;
    is-enabled|disable|enable|restart) return 0 ;;
    *) return 99 ;;
  esac
}
"""
            for name, value in {
                "CALLS": shlex.quote(str(calls)), "STATE": shlex.quote(state),
                "SHOW_OK": "true" if show_ok else "false",
                "RELOAD_OK": "true" if reload_ok else "false",
                "SOCKET_OK": "true" if socket_ok else "false",
                "SERVICE_OK": "true" if service_ok else "false",
            }.items():
                stubs = stubs.replace(name, value)
            script = PRELUDE + APPLY_SSH + "\n" + stubs
            script += f"\nSSH_PORT={shlex.quote(port)}\napply_ssh_hardening\necho REACHED_COMPLETE\n"
            result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
            return result, calls.read_text().splitlines()

    def test_running_service_reload_success(self):
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reload ssh.service", calls)

    def test_reload_failure_prevents_completion(self):
        result, calls = self.run_apply(reload_ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REACHED_COMPLETE", result.stdout)
        self.assertIn("failed to reload ssh.service", result.stderr)
        self.assertNotIn("reload sshd", calls)

    def test_service_dying_after_reload_is_an_error(self):
        result, _ = self.run_apply(service_ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REACHED_COMPLETE", result.stdout)

    def test_inactive_service_with_socket_is_allowed_without_reload(self):
        result, calls = self.run_apply(state="inactive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is-active --quiet ssh.socket", calls)
        self.assertFalse(any(call.startswith("reload") for call in calls))

    def test_inactive_service_without_socket_is_an_error(self):
        result, _ = self.run_apply(state="inactive", socket_ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REACHED_COMPLETE", result.stdout)

    def test_failed_or_transitional_service_is_not_treated_as_socket_wait(self):
        for state in ("failed", "activating", "deactivating", "unknown"):
            with self.subTest(state=state):
                result, calls = self.run_apply(state=state)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("REACHED_COMPLETE", result.stdout)
                self.assertNotIn("is-active --quiet ssh.socket", calls)

    def test_state_query_failure_is_an_error(self):
        result, _ = self.run_apply(show_ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REACHED_COMPLETE", result.stdout)

    def test_custom_port_still_switches_to_service(self):
        result, calls = self.run_apply(port="2222")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("disable --now ssh.socket", calls)
        self.assertIn("restart ssh.service", calls)


if __name__ == "__main__":
    unittest.main(verbosity=2)
