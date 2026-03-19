CREATE TABLE files (
    id INTEGER PRIMARY KEY,
    parent TEXT,
    name TEXT,
    size INTEGER,
    mtime INTEGER,
    is_dir INTEGER,

    UNIQUE(parent, name)
);

CREATE INDEX idx_parent ON files(parent);
CREATE INDEX idx_name ON files(name);
CREATE INDEX idx_mtime ON files(mtime);
