<?php

namespace OctoCat\SupplierPortal\Controllers;

use OctoCat\SupplierPortal\Auth\SessionAuth;
use OctoCat\SupplierPortal\Models\SupplierNote;

class NoteController
{
    private SupplierNote $noteModel;
    private SessionAuth $auth;

    public function __construct()
    {
        $this->noteModel = new SupplierNote();
        $this->auth = new SessionAuth();
        $this->auth->startSession();
    }

    public function index(): void
    {
        $supplierId = $this->auth->getSupplierId();
        $supplierName = $this->auth->getSupplierName();

        $category = $_GET['category'] ?? null;
        $search = $_GET['search'] ?? null;

        if ($search) {
            $notes = $this->noteModel->search($supplierId, $search);
        } elseif ($category) {
            $notes = $this->noteModel->findByCategory($supplierId, $category);
        } else {
            $notes = $this->noteModel->findBySupplierId($supplierId);
        }

        $categoryCounts = $this->noteModel->getCategoryCounts($supplierId);

        require __DIR__ . '/../../templates/notes.php';
    }

    public function show(int $id): void
    {
        $note = $this->noteModel->findById($id);
        $supplierName = $this->auth->getSupplierName();

        if (!$note) {
            http_response_code(404);
            echo 'Note not found.';
            return;
        }

        if ($note['supplier_id'] !== $this->auth->getSupplierId()) {
            http_response_code(403);
            echo 'Access denied.';
            return;
        }

        require __DIR__ . '/../../templates/note_detail.php';
    }

    public function create(): void
    {
        $supplierName = $this->auth->getSupplierName();

        if ($_SERVER['REQUEST_METHOD'] === 'GET') {
            require __DIR__ . '/../../templates/note_form.php';
            return;
        }

        $supplierId = $this->auth->getSupplierId();
        $data = [
            'supplier_id' => $supplierId,
            'author_name' => trim($_POST['author_name'] ?? ''),
            'title' => trim($_POST['title'] ?? ''),
            'content' => $_POST['content'] ?? '',
            'category' => $_POST['category'] ?? 'general',
            'is_pinned' => isset($_POST['is_pinned']) ? 1 : 0,
        ];

        $errors = $this->validateNote($data);
        if (!empty($errors)) {
            require __DIR__ . '/../../templates/note_form.php';
            return;
        }

        $id = $this->noteModel->create($data);
        header("Location: /notes/{$id}");
        exit;
    }

    public function update(int $id): void
    {
        $note = $this->noteModel->findById($id);
        $supplierName = $this->auth->getSupplierName();

        if (!$note || $note['supplier_id'] !== $this->auth->getSupplierId()) {
            http_response_code(403);
            echo 'Access denied.';
            return;
        }

        if ($_SERVER['REQUEST_METHOD'] === 'GET') {
            $data = $note;
            require __DIR__ . '/../../templates/note_form.php';
            return;
        }

        $data = [
            'title' => trim($_POST['title'] ?? ''),
            'content' => $_POST['content'] ?? '',
            'category' => $_POST['category'] ?? 'general',
            'is_pinned' => isset($_POST['is_pinned']) ? 1 : 0,
        ];

        $errors = $this->validateNote($data);
        if (!empty($errors)) {
            require __DIR__ . '/../../templates/note_form.php';
            return;
        }

        $this->noteModel->update($id, $data);
        header("Location: /notes/{$id}");
        exit;
    }

    public function destroy(int $id): void
    {
        $note = $this->noteModel->findById($id);
        if (!$note || $note['supplier_id'] !== $this->auth->getSupplierId()) {
            http_response_code(403);
            echo 'Access denied.';
            return;
        }

        $this->noteModel->delete($id);
        header('Location: /notes');
        exit;
    }

    public function togglePin(int $id): void
    {
        $note = $this->noteModel->findById($id);
        if (!$note || $note['supplier_id'] !== $this->auth->getSupplierId()) {
            http_response_code(403);
            echo 'Access denied.';
            return;
        }

        $this->noteModel->togglePin($id);
        header("Location: /notes/{$id}");
        exit;
    }

    private function validateNote(array $data): array
    {
        $errors = [];

        if (empty($data['title'])) {
            $errors[] = 'Title is required.';
        }
        if (strlen($data['title'] ?? '') > 200) {
            $errors[] = 'Title must be under 200 characters.';
        }
        if (empty($data['content'])) {
            $errors[] = 'Note content is required.';
        }

        $validCategories = ['general', 'shipping', 'quality', 'billing', 'urgent'];
        if (!in_array($data['category'] ?? '', $validCategories, true)) {
            $errors[] = 'Invalid category.';
        }

        return $errors;
    }
}
