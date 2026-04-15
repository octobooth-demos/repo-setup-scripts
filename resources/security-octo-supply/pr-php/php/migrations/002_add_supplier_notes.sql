-- Supplier Portal Schema Update
-- Migration 002: Add supplier_notes table for internal communication

CREATE TABLE IF NOT EXISTS supplier_notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    supplier_id INTEGER NOT NULL,
    author_name TEXT NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'general' CHECK(category IN ('general', 'shipping', 'quality', 'billing', 'urgent')),
    is_pinned INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_notes_supplier ON supplier_notes(supplier_id);
CREATE INDEX IF NOT EXISTS idx_notes_category ON supplier_notes(category);
