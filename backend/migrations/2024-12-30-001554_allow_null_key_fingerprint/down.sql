-- First copy everything to a temp table without constraints
CREATE TABLE host_temp AS SELECT * FROM host;
DROP TABLE host;

-- Create the final table with all constraints
CREATE TABLE host (
	id INTEGER NOT NULL PRIMARY KEY,
	name TEXT UNIQUE NOT NULL,
	username TEXT NOT NULL,
	address TEXT UNIQUE NOT NULL,
	port INTEGER NOT NULL,
	key_fingerprint TEXT UNIQUE NOT NULL,
	jump_via INTEGER,
	FOREIGN KEY (jump_via) REFERENCES host(id) ON DELETE CASCADE
);

-- Copy only the records that satisfy the NOT NULL constraint on key_fingerprint
INSERT INTO host
SELECT * FROM host_temp
WHERE key_fingerprint IS NOT NULL;

DROP TABLE host_temp;
