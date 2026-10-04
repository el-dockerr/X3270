import subprocess
import json
import time
import os

class DX3270Client:
    def __init__(self, host: str, port: int = 23, binary_path: str = None):
        if binary_path is None:
            base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            binary_path = os.path.join(base_dir, "build_release", "dx3270_headless")
            
        if not os.path.exists(binary_path):
            raise FileNotFoundError(f"Executable not found at: {binary_path}. Run ./package.sh first.")

        self.binary_path = binary_path
        self.host = host
        self.port = str(port)
        self.process = None

    def start(self):
        self.process = subprocess.Popen(
            [self.binary_path, self.host, self.port],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1
        )

    def read_screen_json(self, timeout: float = 5.0) -> dict:
        """Reads and decodes the JSON map emitted by the engine."""
        start_time = time.time()

        while time.time() - start_time < timeout:
            line = self.process.stdout.readline()
            if not line:
                break
            
            line_str = line.strip()
            
            # Ignore informational or decorative logs from stdout
            if line_str.startswith("[") or line_str.startswith("=") or not line_str:
                continue

            # Attempt to parse the JSON line
            if line_str.startswith("{") and line_str.endswith("}"):
                try:
                    data = json.loads(line_str)
                    # Verify that it is the root screen object and not a sub-block
                    if "grid" in data or "fields" in data or "panel_title" in data:
                        return data
                except json.JSONDecodeError:
                    continue

        raise TimeoutError("Timeout while waiting for JSON from the ScreenStructuralAnalyzer.")

    def send_command(self, fields: dict = None, aid: str = "ENTER") -> dict:
        formatted_fields = {}
        if fields:
            for key, val in fields.items():
                # Supporta sia nomi di campo che coordinate tipo "0,26" o "FIELD_R1_C27"
                formatted_fields[key] = val

        payload = {
            "action": "submit",
            "fields": formatted_fields,
            "aid": aid
        }
        
        cmd_str = json.dumps(payload) + "\n"
        self.process.stdin.write(cmd_str)
        self.process.stdin.flush()
        
        return self.read_screen_json()

    def stop(self):
        if self.process:
            self.process.terminate()
            self.process.wait()