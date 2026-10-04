import sys
import os
import unittest

# Adds the parent directory to the path to import dx3270_client
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dx3270_client import DX3270Client

class TestMainframeJSONAutomation(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        # Mainframe z/OS parameters
        cls.HOST = "10.134.49.215"
        cls.PORT = 23
        
        print("\n[*] Starting DX3270 Headless engine...")
        cls.client = DX3270Client(host=cls.HOST, port=cls.PORT)
        cls.client.start()

    @classmethod
    def tearDownClass(cls):
        print("\n[*] Closing session...")
        cls.client.stop()

    def test_01_initial_screen_and_label_recognition(self):
        """Tests the connection and heuristic recognition of the initial screen."""
        screen = self.client.read_screen_json(timeout=5.0)
        
        print("\n[+] Initial screen received:")
        print(f"    - Panel Title: '{screen.get('panel_title')}'")
        print(f"    - Grid: {screen.get('grid')}")
        print(f"    - Recognized Fields: {len(screen.get('fields', []))}")
        
        # Verifiche sull'output JSON dell'Analyzer
        self.assertIn("grid", screen)
        self.assertEqual(screen["grid"]["rows"], 24)
        self.assertEqual(screen["grid"]["cols"], 80)
        
        # Search for the field with the label "USERID" auto-assigned by the analyzer
        fields = screen.get("fields", [])
        userid_field = next((f for f in fields if f.get("name") == "USERID"), None)
        
        if userid_field:
            print(f"[✓] USERID field successfully found at coordinates R{userid_field['row']+1}:C{userid_field['col']+1}")
            self.assertEqual(userid_field["type"], "input")

    def test_02_submit_userid(self):
        """Tests sending the JSON command for automatic filling and pressing the ENTER key."""
        print("\n[*] Sending User ID via JSON...")
        
        # Fills the "USERID" field with "TONDI" and sends ENTER
        next_screen = self.client.send_command(
            fields={"USERID": "TONDI"},
            aid="ENTER"
        )
        
        print("[+] Response received from the Mainframe after sending:")
        print(f"    - Panel Title: '{next_screen.get('panel_title')}'")
        print(f"    - Cursor: {next_screen.get('cursor')}")
        
        self.assertIsNotNone(next_screen)

if __name__ == "__main__":
    unittest.main()