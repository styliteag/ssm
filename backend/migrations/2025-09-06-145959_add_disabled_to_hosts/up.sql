-- Add disabled column to host table  
ALTER TABLE host ADD COLUMN disabled BOOLEAN NOT NULL DEFAULT 0;