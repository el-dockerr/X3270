import sys
import os
import unittest
import time
import json

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from dx3270_client import DX3270Client

class TestSDSFWorkflow(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.HOST = "10.134.49.215"
        cls.PORT = 23
        cls.USERID = os.getenv("TSO_USER", "TONDI")
        cls.PASSWORD = os.getenv("TSO_PASS", "TONDI25")

        print(f"\n[*] Starting DX3270 Headless engine for target {cls.HOST}:{cls.PORT}...")
        cls.client = DX3270Client(host=cls.HOST, port=cls.PORT)
        cls.client.start()

    @classmethod
    def tearDownClass(cls):
        print("\n[*] Closing Headless session...")
        cls.client.stop()

    def print_full_screen_json(self, step_name: str, screen_json: dict):
        if not screen_json:
            print(f"\n[!] Timeout o schermo vuoto per {step_name}")
            return
        print(f"\n==================================================================")
        print(f" FULL JSON TRACE - {step_name}")
        print(f"==================================================================")
        print(json.dumps(screen_json, indent=2, ensure_ascii=False))
        print(f"==================================================================\n")

    def wait_for_condition(self, condition_func, timeout=10.0):
        start_time = time.time()
        last_screen = None
        while time.time() - start_time < timeout:
            screen = self.client.read_screen_json(timeout=0.5)
            if screen:
                last_screen = screen
                if len(screen.get("fields", [])) > 0 and condition_func(screen):
                    return screen
        return last_screen

    def test_full_sdsf_workflow(self):
        # ----------------------------------------------------------------------
        # STEP 1: INITIAL SCREEN
        # ----------------------------------------------------------------------
        screen = self.wait_for_condition(lambda s: any(f.get("type") == "input" for f in s.get("fields", [])))
        self.print_full_screen_json("STEP 1: INITIAL SCREEN", screen)

        # ----------------------------------------------------------------------
        # STEP 2: USERID SUBMIT
        # ----------------------------------------------------------------------
        inputs = [f.get("name") for f in screen.get("fields", []) if f.get("type") == "input"]
        target_field = "USERID" if "USERID" in inputs else inputs[0]
        self.client.send_command(fields={target_field: self.USERID}, aid="ENTER")
        
        screen = self.wait_for_condition(lambda s: any(f.get("type") == "secret" for f in s.get("fields", [])))
        self.print_full_screen_json("STEP 2: POST USERID (TSO/E LOGON)", screen)
        title_step2 = screen.get('panel_title', '')

        # ----------------------------------------------------------------------
        # STEP 3: PASSWORD SUBMIT
        # ----------------------------------------------------------------------
        secret_fields = [f for f in screen.get("fields", []) if f.get("type") == "secret"]
        target_pass = "Password" if any(f.get("name") == "Password" for f in secret_fields) else secret_fields[0].get("name")
        self.client.send_command(fields={target_pass: self.PASSWORD}, aid="ENTER")
            
        screen = self.wait_for_condition(
            lambda s: s.get('panel_title', '').strip() != title_step2.strip() or "IKJ" in json.dumps(s)
        )
        self.print_full_screen_json("STEP 3: POST PASSWORD", screen)

        # ----------------------------------------------------------------------
        # STEP 3.5: CLEAR POST-LOGON MESSAGES
        # ----------------------------------------------------------------------
        print("\n[!] Clearing post-logon messages...")
        for _ in range(10):
            if not screen: break
            title = screen.get('panel_title', '').strip()
            fields = screen.get('fields', [])
            inputs = [f.get("name") for f in fields if f.get("type") == "input"]
            
            is_tso_ready = any("READY" in f.get("value", "") for f in fields)
            is_ispf_menu = any(cmd_field in inputs for cmd_field in ["OPTION", "Command", "ZCMD"])
            
            if is_tso_ready or is_ispf_menu:
                break

            is_message = False
            if title == "" and len(fields) == 1 and fields[0].get("name") == "FIELD_R1_C1":
                is_message = True
            elif title.startswith(("ICH", "IKT", "IKJ", "IEA")) or "LAST ACCESS" in title or "***" in title:
                is_message = True
                
            if is_message:
                print(f"    - Bypassing message screen: '{title}'")
                self.client.send_command(aid="ENTER")
                time.sleep(0.2)
                screen = self.wait_for_condition(lambda s: True)
            else:
                break
                
        self.print_full_screen_json("STEP 3.5: ENVIRONMENT REACHED", screen)

        # ----------------------------------------------------------------------
        # STEP 4: LAUNCH ISPF AND SDSF
        # ----------------------------------------------------------------------
        if screen:
            fields = screen.get("fields", [])
            inputs = [f.get("name") for f in fields if f.get("type") == "input"]
            is_tso_ready = any("READY" in f.get("value", "") for f in fields)
            
            if is_tso_ready:
                print("\n[!] TSO READY prompt detected. Launching ISPF environment...")
                target_cmd = "READY" if "READY" in inputs else inputs[-1]
                self.client.send_command(fields={target_cmd: "ISPF"}, aid="ENTER")
                
                # Attesa dell'uscita dal prompt READY
                screen = self.wait_for_condition(lambda s: not any("READY" in f.get("value", "") for f in s.get("fields", [])))
                self.print_full_screen_json("STEP 4.1: POST ISPF COMMAND", screen)
                
                # Bypass di eventuali schermate di benvenuto / Copyright ISPF
                print("\n[!] Waiting for ISPF Primary Option Menu...")
                for _ in range(3):
                    if not screen: break
                    inputs = [f.get("name") for f in screen.get("fields", []) if f.get("type") == "input"]
                    if any(cmd_field in inputs for cmd_field in ["OPTION", "Command", "ZCMD"]):
                        break
                    print("    - Bypassing ISPF Welcome/Copyright screen...")
                    self.client.send_command(aid="ENTER")
                    time.sleep(0.3)
                    screen = self.wait_for_condition(lambda s: True)
                    
                self.print_full_screen_json("STEP 4.2: ISPF MENU READY", screen)

                # Invia il comando SDSF (=S)
                inputs = [f.get("name") for f in screen.get("fields", []) if f.get("type") == "input"]
                if inputs:
                    target_cmd = next((name for name in ["OPTION", "Command", "ZCMD"] if name in inputs), inputs[0])
                    self.client.send_command(fields={target_cmd: "=S"}, aid="ENTER")
                    current_title = screen.get('panel_title', '')
                    screen = self.wait_for_condition(lambda s: s.get('panel_title', '') != current_title)
                    self.print_full_screen_json("STEP 4.3: POST SDSF COMMAND", screen)
            else:
                if inputs:
                    target_cmd = next((name for name in ["OPTION", "Command", "ZCMD"] if name in inputs), inputs[0])
                    self.client.send_command(fields={target_cmd: "=S"}, aid="ENTER")
                    current_title = screen.get('panel_title', '')
                    screen = self.wait_for_condition(lambda s: s.get('panel_title', '') != current_title)
                    self.print_full_screen_json("STEP 4: POST SDSF COMMAND", screen)

if __name__ == "__main__":
    unittest.main()