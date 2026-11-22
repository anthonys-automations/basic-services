import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RuntimeTests(unittest.TestCase):
    def run_bash(self, script, env=None, check=True):
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            env=env,
            text=True,
            capture_output=True,
            check=check,
        )

    def test_disconnect_grace_and_concurrent_ssh(self):
        source = (ROOT / "sandbox-browser/scripts/entrypoint.sh").read_text()
        functions = source.split("rdp_session_markers_present() {", 1)[1]
        functions = "rdp_session_markers_present() {" + functions.split(
            "sessions_active() {", 1
        )[0]
        functions = functions.replace('"/proc/${marker##*/}/comm"', '"$marker"')
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_bash(
                functions
                + r"""
sessions_dir=$TEST_DIR
rdp_disconnected_since=""
rdp_disconnect_grace_seconds=30
clock=100
connected=""
ss() { printf '%s' "$connected"; }
date() { printf '%s\n' "$clock"; }
read() {
  if [[ ${*: -1} == comm ]]; then
    IFS= builtin read -r comm
    [[ $comm == rdp ]] && comm=xrdp-sesman
    return 0
  fi
  builtin read "$@"
}
printf 'rdp\n' > "$sessions_dir/101"
printf 'ssh\n' > "$sessions_dir/102"
reap_disconnected_rdp_session
clock=101
reap_disconnected_rdp_session
[[ -f "$sessions_dir/101" ]]
connected=client
reap_disconnected_rdp_session
[[ -z $rdp_disconnected_since ]]
connected=""
clock=200
reap_disconnected_rdp_session
clock=229
reap_disconnected_rdp_session
[[ -f "$sessions_dir/101" ]]
clock=230
reap_disconnected_rdp_session
[[ ! -e "$sessions_dir/101" && -f "$sessions_dir/102" ]]
reap_disconnected_rdp_session
""",
                env={**os.environ, "TEST_DIR": directory},
            )
            self.assertIn("No RDP client connected for 30s", result.stdout)

    def test_proxy_environment_allowlist(self):
        for service in ("sandbox-browser", "devbox"):
            source = (ROOT / service / "scripts/entrypoint.sh").read_text()
            lines = source.split(': > "$runtime_dir/session.env"', 1)[1].splitlines()
            writer = ': > "$runtime_dir/session.env"\n'
            for line in lines:
                writer += line + "\n"
                if line.strip() == "done":
                    break
            for variables in (
                {},
                {
                    "http_proxy": "http://proxy.example:8888",
                    "https_proxy": "http://user:pass@proxy.example:8888",
                    "all_proxy": "socks5h://socks.example:1080",
                    "no_proxy": "localhost,.svc,10.0.0.0/8",
                    "HTTP_PROXY": "",
                    "HTTPS_PROXY": "http://upper.example:3128",
                    "ALL_PROXY": "socks5://upper.example:1080",
                    "NO_PROXY": "::1",
                },
            ):
                with self.subTest(service=service, variables=variables):
                    with tempfile.TemporaryDirectory() as directory:
                        self.run_bash(
                            'runtime_dir=$TEST_DIR\n' + writer,
                            env={
                                "PATH": os.environ["PATH"],
                                "TEST_DIR": directory,
                                "UNRELATED_SECRET": "not-forwarded",
                                **variables,
                            },
                        )
                        path = Path(directory) / "session.env"
                        self.assertEqual(
                            path.read_text().splitlines(),
                            [f"{key}={value}" for key, value in variables.items()],
                        )
                        self.assertEqual(path.stat().st_mode & 0o777, 0o644)
            with tempfile.TemporaryDirectory() as directory:
                result = self.run_bash(
                    'runtime_dir=$TEST_DIR\n' + writer,
                    env={
                        "PATH": os.environ["PATH"],
                        "TEST_DIR": directory,
                        "https_proxy": "http://proxy\nINJECTED=value",
                    },
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be single-line", result.stderr)

    @unittest.skipUnless(shutil.which("node"), "node is required")
    def test_browser_autoconfig_proxy(self):
        config = ROOT / "sandbox-browser/config"
        parser = (config / "browser-proxy.js").read_text()
        firefox = parser + (config / "firefox/desktop.cfg").read_text()

        def evaluate(source, variables):
            harness = (
                "const env = JSON.parse(process.argv[1]), prefs = {};"
                "const getenv = name => env[name] || '';"
                "const defaultPref = (name, value) => { prefs[name] = value; };"
                "const lockPref = defaultPref;"
                "eval(require('fs').readFileSync(0, 'utf8'));"
                "console.log(JSON.stringify(prefs));"
            )
            result = subprocess.run(
                ["node", "-e", harness, json.dumps(variables)],
                input=source,
                text=True,
                capture_output=True,
                check=True,
            )
            return {k: v for k, v in json.loads(result.stdout).items() if "proxy" in k}

        self.assertEqual(evaluate(firefox, {}), {})
        self.assertEqual(evaluate(firefox, {"HTTP_PROXY": "not a url"}), {})
        variables = {
            "HTTP_PROXY": "http://user:pass@proxy.example:3128/",
            "HTTPS_PROXY": "https://[fd00::1]",
            "no_proxy": "localhost,.svc",
        }
        self.assertEqual(
            evaluate(firefox, variables),
            {
                "network.proxy.type": 1,
                "network.proxy.http": "proxy.example",
                "network.proxy.http_port": 3128,
                "network.proxy.ssl": "fd00::1",
                "network.proxy.ssl_port": 443,
                "network.proxy.no_proxies_on": "localhost,.svc",
            },
        )
        self.assertEqual(
            evaluate(firefox, {**variables, "ALL_PROXY": "socks5h://user:pass@socks.example"}),
            {
                "network.proxy.type": 1,
                "network.proxy.socks": "socks.example",
                "network.proxy.socks_port": 1080,
                "network.proxy.socks_version": 5,
                "network.proxy.socks5_remote_dns": True,
                "network.proxy.no_proxies_on": "localhost,.svc",
            },
        )
        self.assertEqual(
            evaluate(firefox, {"all_proxy": "http://all.example:8080", "http_proxy": "socks5://x:1"}),
            {
                "network.proxy.type": 1,
                "network.proxy.http": "all.example",
                "network.proxy.http_port": 8080,
                "network.proxy.ssl": "all.example",
                "network.proxy.ssl_port": 8080,
            },
        )
        self.assertEqual(evaluate(firefox, {"http_proxy": "socks5://socks.example:1080"}), {})

    def test_xrdp_keymap_modifiers(self):
        script = ROOT / "sandbox-browser/scripts/normalize-xrdp-keymaps.py"
        keymap = (
            "[noshift]\r\nKey38=97:97\r\nKey64=65513:0\r\nKey113=65027:0\r\n"
            "[shift]\r\nKey38=65:65\r\nKey64=65032:0\r\nKey113=65312:0\r\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "km-00000409.ini"
            path.write_bytes(keymap.encode())
            for _ in range(2):
                subprocess.run(["python3", script, path], check=True, capture_output=True)
                self.assertEqual(
                    path.read_bytes().decode(),
                    keymap.replace("Key64=65032", "Key64=65513").replace("Key113=65312", "Key113=65027"),
                )


if __name__ == "__main__":
    unittest.main()
