<?php
$pageTitle = htmlspecialchars($note['title']);
ob_start();
?>

<div style="margin-bottom: 1rem;">
    <a href="/notes" style="color: #0366d6; text-decoration: none; font-size: 0.9rem;">← Back to Notes</a>
</div>

<div class="card">
    <div style="display: flex; justify-content: space-between; align-items: start; margin-bottom: 1rem;">
        <div>
            <?php if ($note['is_pinned']): ?>
                <span class="badge badge-pending">📌 Pinned</span>
            <?php endif; ?>
            <span class="badge badge-<?= $note['category'] === 'urgent' ? 'low' : 'active' ?>">
                <?= ucfirst(htmlspecialchars($note['category'])) ?>
            </span>
        </div>
        <div style="display: flex; gap: 0.5rem;">
            <form method="POST" action="/notes/<?= $note['id'] ?>/pin" style="display: inline;">
                <button type="submit" class="btn btn-secondary" style="font-size: 0.85rem;">
                    <?= $note['is_pinned'] ? 'Unpin' : 'Pin' ?>
                </button>
            </form>
            <a href="/notes/<?= $note['id'] ?>/edit" class="btn btn-primary" style="font-size: 0.85rem;">Edit</a>
            <form method="POST" action="/notes/<?= $note['id'] ?>/delete" style="display: inline;"
                  onsubmit="return confirm('Delete this note?')">
                <button type="submit" class="btn btn-danger" style="font-size: 0.85rem;">Delete</button>
            </form>
        </div>
    </div>

    <h1 style="margin-bottom: 0.5rem;"><?= $note['title'] ?></h1>

    <div style="font-size: 0.85rem; color: #586069; margin-bottom: 1.5rem;">
        Written by <strong><?= $note['author_name'] ?></strong>
        on <?= date('F j, Y \a\t g:i A', strtotime($note['created_at'])) ?>
        <?php if ($note['updated_at'] !== $note['created_at']): ?>
            · <em>Updated <?= date('M j, Y g:ia', strtotime($note['updated_at'])) ?></em>
        <?php endif; ?>
    </div>

    <div class="note-content" style="line-height: 1.8; white-space: pre-wrap;">
<?= $note['content'] ?>
    </div>
</div>

<?php
$content = ob_get_clean();
require __DIR__ . '/layout.php';
?>
