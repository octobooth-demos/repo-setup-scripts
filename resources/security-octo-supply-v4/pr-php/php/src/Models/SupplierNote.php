<?php

namespace OctoCat\SupplierPortal\Models;

class SupplierNote
{
    private Database $db;

    public function __construct()
    {
        $this->db = Database::getInstance();
    }

    public function findById(int $id): ?array
    {
        return $this->db->fetchOne(
            'SELECT n.*, s.company_name as supplier_name
             FROM supplier_notes n
             JOIN suppliers s ON n.supplier_id = s.id
             WHERE n.id = ?',
            [$id]
        );
    }

    public function findBySupplierId(int $supplierId, int $limit = 50, int $offset = 0): array
    {
        return $this->db->fetchAll(
            'SELECT * FROM supplier_notes
             WHERE supplier_id = ?
             ORDER BY is_pinned DESC, created_at DESC
             LIMIT ? OFFSET ?',
            [$supplierId, $limit, $offset]
        );
    }

    public function findByCategory(int $supplierId, string $category): array
    {
        return $this->db->fetchAll(
            'SELECT * FROM supplier_notes
             WHERE supplier_id = ? AND category = ?
             ORDER BY is_pinned DESC, created_at DESC',
            [$supplierId, $category]
        );
    }

    public function create(array $data): int
    {
        return $this->db->insert('supplier_notes', [
            'supplier_id' => $data['supplier_id'],
            'author_name' => $data['author_name'],
            'title' => $data['title'],
            'content' => $data['content'],
            'category' => $data['category'] ?? 'general',
            'is_pinned' => $data['is_pinned'] ?? 0,
            'created_at' => date('Y-m-d H:i:s'),
            'updated_at' => date('Y-m-d H:i:s'),
        ]);
    }

    public function update(int $id, array $data): int
    {
        $data['updated_at'] = date('Y-m-d H:i:s');
        return $this->db->update('supplier_notes', $data, 'id = ?', [$id]);
    }

    public function delete(int $id): int
    {
        return $this->db->delete('supplier_notes', 'id = ?', [$id]);
    }

    public function togglePin(int $id): int
    {
        $note = $this->findById($id);
        if (!$note) {
            throw new \RuntimeException("Note not found: {$id}");
        }

        $newPinState = $note['is_pinned'] ? 0 : 1;
        return $this->update($id, ['is_pinned' => $newPinState]);
    }

    public function search(int $supplierId, string $query): array
    {
        $likeQuery = "%{$query}%";
        return $this->db->fetchAll(
            'SELECT * FROM supplier_notes
             WHERE supplier_id = ?
               AND (title LIKE ? OR content LIKE ? OR author_name LIKE ?)
             ORDER BY created_at DESC',
            [$supplierId, $likeQuery, $likeQuery, $likeQuery]
        );
    }

    public function getRecentNotes(int $supplierId, int $count = 5): array
    {
        return $this->db->fetchAll(
            'SELECT * FROM supplier_notes
             WHERE supplier_id = ?
             ORDER BY created_at DESC
             LIMIT ?',
            [$supplierId, $count]
        );
    }

    public function getCategoryCounts(int $supplierId): array
    {
        return $this->db->fetchAll(
            'SELECT category, COUNT(*) as count
             FROM supplier_notes
             WHERE supplier_id = ?
             GROUP BY category
             ORDER BY count DESC',
            [$supplierId]
        );
    }
}
