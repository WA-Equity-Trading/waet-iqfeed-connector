#!/usr/bin/env python3
"""Launch IQFeed client with proper configuration"""
import subprocess
import sys
import os
import time

def launch_iqfeed():
    """Launch IQFeed client with credentials"""
    login = os.environ.get('LOGIN', '523028')
    password = os.environ.get('PASSWORD', 'zisbiv-xUszub-2gugta')
    product_id = os.environ.get('PRODUCT_ID', 'IQFEED_DEMO')
    version = os.environ.get('VERSION', '6.2.0.25')
    
    # Use patched version if available
    iqconnect_path = '/root/.wine/drive_c/Program Files/DTN/IQFeed/iqconnect_patched.exe'
    if not os.path.exists(iqconnect_path):
        iqconnect_path = '/root/.wine/drive_c/Program Files/DTN/IQFeed/iqconnect.exe'
    
    if not os.path.exists(iqconnect_path):
        print("ERROR: IQFeed client not found at:", iqconnect_path)
        sys.exit(1)
    
    cmd = [
        'wine64',
        iqconnect_path,
        '-autoconnect',
        '-product', product_id,
        '-version', version,
        '-login', login,
        '-password', password
    ]
    
    print("Launching IQFeed client...")
    print("Command:", ' '.join(cmd))
    
    # Set Wine environment
    env = os.environ.copy()
    env['WINEPREFIX'] = '/root/.wine'
    env['DISPLAY'] = ':0'
    env['WINEDEBUG'] = '-all'
    
    # Launch in background
    proc = subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    
    print(f"IQFeed client started with PID: {proc.pid}")
    
    # Wait a bit to see if it crashes immediately
    time.sleep(3)
    if proc.poll() is not None:
        stdout, stderr = proc.communicate()
        print("ERROR: IQFeed client crashed immediately")
        print("STDOUT:", stdout.decode())
        print("STDERR:", stderr.decode())
        sys.exit(1)
    
    print("IQFeed client appears to be running")
    return proc.pid

if __name__ == '__main__':
    launch_iqfeed()
