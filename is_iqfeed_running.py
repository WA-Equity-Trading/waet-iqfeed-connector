#!/usr/bin/env python3
"""Check if IQFeed is running and listening on ports"""
import subprocess
import socket
import sys

def check_port(host, port):
    """Check if a port is open"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except Exception as e:
        print(f"Error checking port {port}: {e}")
        return False

def is_iqfeed_running():
    """Check if IQFeed is running"""
    # Check for wine processes
    try:
        result = subprocess.run(
            ['ps', 'aux'],
            capture_output=True,
            text=True
        )
        
        has_wine_process = 'iqconnect' in result.stdout.lower()
        
        # Check if admin port is listening (9300)
        admin_port_open = check_port('127.0.0.1', 9300)
        
        # Check if level1 port is listening (9100)
        level1_port_open = check_port('127.0.0.1', 9100)
        
        print(f"Wine process running: {has_wine_process}")
        print(f"Admin port (9300) open: {admin_port_open}")
        print(f"Level1 port (9100) open: {level1_port_open}")
        
        if admin_port_open and level1_port_open:
            print("✓ IQFeed is running and serving data")
            return True
        elif has_wine_process:
            print("⚠ IQFeed process exists but ports not ready")
            return False
        else:
            print("✗ IQFeed is not running")
            return False
            
    except Exception as e:
        print(f"Error checking IQFeed status: {e}")
        return False

if __name__ == '__main__':
    running = is_iqfeed_running()
    sys.exit(0 if running else 1)
