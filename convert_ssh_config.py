#!/usr/bin/env python3

import os
import sys
from pathlib import Path
from typing import Dict, List, Set
import sqlite3
 
def create_database(cursor):
    """Create the database tables if they don't exist."""
    # First drop all tables to start fresh
    # cursor.execute('DROP TABLE IF EXISTS host')
    
    # Create new table with our schema
    #cursor.execute('''
    #    CREATE TABLE host if not exist (
    #        id INTEGER PRIMARY KEY AUTOINCREMENT,
    #        name TEXT PRIMARY KEY,
    #        address TEXT NOT NULL,
    #        username TEXT NOT NULL,
    #        port INTEGER NOT NULL,
    #        jump_via TEXT
    #    )
    #''')

def parse_ssh_config_file(config_file: Path, processed_files: Set[Path] = None) -> Dict[str, Dict[str, str]]:
    """
    Parse an SSH config file and return a dictionary of hosts and their configurations.
    Handles Include directives recursively.
    """
    if processed_files is None:
        processed_files = set()
    
    if config_file in processed_files:
        return {}
    
    processed_files.add(config_file)
    hosts = {}
    current_host = None
    current_config = {}

    try:
        with open(config_file, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue

                parts = line.split(None, 1)
                if not parts:
                    continue

                keyword = parts[0].lower()
                if len(parts) > 1:
                    value = parts[1]
                else:
                    value = ''

                if keyword == 'host':
                    if current_host:
                        for host in current_host.split():
                            hosts[host] = current_config.copy()
                    current_host = value
                    current_config = {}
                elif keyword == 'include':
                    # Handle Include directive
                    include_path = os.path.expanduser(value)
                    if '*' in include_path:
                        # Handle wildcards in include path
                        base_dir = os.path.dirname(include_path)
                        pattern = os.path.basename(include_path)
                        base_dir = os.path.expanduser(base_dir)
                        if os.path.exists(base_dir):
                            for entry in os.listdir(base_dir):
                                if entry.startswith('.'):  # Skip hidden files
                                    continue
                                full_path = Path(os.path.join(base_dir, entry))
                                if full_path.is_file() and full_path.match(pattern):
                                    included_hosts = parse_ssh_config_file(full_path, processed_files)
                                    hosts.update(included_hosts)
                    else:
                        include_path = Path(include_path)
                        if include_path.is_file():
                            included_hosts = parse_ssh_config_file(include_path, processed_files)
                            hosts.update(included_hosts)
                elif current_host:
                    current_config[keyword] = value

        # Don't forget the last host in the file
        if current_host:
            for host in current_host.split():
                hosts[host] = current_config.copy()

    except Exception as e:
        print(f"Error processing {config_file}: {e}", file=sys.stderr)

    return hosts

def main():
    ssh_config = Path(os.path.expanduser("~/.ssh/config"))
    if not ssh_config.is_file():
        print(f"SSH config file not found: {ssh_config}", file=sys.stderr)
        sys.exit(1)

    hosts = parse_ssh_config_file(ssh_config)
    conn = sqlite3.connect('ssm.db')
    cursor = conn.cursor()
    
    # Create the database tables
    create_database(cursor)
    
    # Print all hosts and their configurations
    for host, config in sorted(hosts.items()):
        print(f"Host: {host}")
        for key, value in sorted(config.items()):
            print(f"  {key}: {value}")
            
        # Skip hosts with wildcards in address
        address = config.get('hostname', host)
        if '*' in address:
            print(f"Skipping host {host} due to wildcard in address: {address}")
            continue
            
        try:
            print(f"Inserting host {host} into the database...")
            proxy_jump = config.get('proxyjump', None)
            if proxy_jump and proxy_jump.lower() == 'none':
                proxy_jump = None
                
            cursor.execute("INSERT INTO host (name, address, username, port, jump_via, key_fingerprint) VALUES (?, ?, ?, ?, ?, '')", 
              (
                host, 
                address,
                config.get('user', 'root'),
                int(config.get('port', '22')),
                proxy_jump
              )
            )
        except Exception as e:
            print(f"Error inserting host {host} into the database: {e}")
            pass

    # Second pass: Update jump_via references to use IDs instead of hostnames
    print("\nUpdating jump_via references to use IDs...")
    cursor.execute("SELECT id, name, jump_via FROM host WHERE jump_via IS NOT NULL")
    hosts_with_jump = cursor.fetchall()
    
    for host_id, host_name, jump_via in hosts_with_jump:
        # Skip if jump_via is already an integer
        if isinstance(jump_via, int):
            continue
            
        if isinstance(jump_via, str) and jump_via.lower() == 'none':
            print(f"Setting jump_via to NULL for {host_name} (was 'none')")
            cursor.execute("UPDATE host SET jump_via = NULL WHERE id = ?", (host_id,))
            continue
            
        # Find the ID of the referenced jump host
        cursor.execute("SELECT id FROM host WHERE name = ?", (jump_via,))
        jump_host = cursor.fetchone()
        if jump_host:
            print(f"Updating {host_name}: changing jump_via from '{jump_via}' to ID {jump_host[0]}")
            cursor.execute("UPDATE host SET jump_via = ? WHERE id = ?", (jump_host[0], host_id))
        else:
            print(f"Warning: Jump host '{jump_via}' referenced by '{host_name}' not found in database")
            cursor.execute("UPDATE host SET jump_via = NULL WHERE id = ?", (host_id,))

    conn.commit()
    conn.close()

if __name__ == "__main__":
    main()
