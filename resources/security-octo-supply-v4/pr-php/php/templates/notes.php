<?php
$pageTitle = 'Notes';
ob_start();
?>

<div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.5rem;">
    <h1>Supplier Notes</h1>
    <a href="/notes/create" class="btn btn-primary">+ New Note</a>
</div>

<!-- Search and Filter -->
<div class="card" style="padding: 1rem;">
    <form method="GET" action="/notes" style="display: flex; gap: 1rem; align-items: end;">
        <div style="flex: 1;">
            <label for="search">Search notes</label>
            <input type="text" id="search" name="search" placeholder="Search by title, content, or author..."
                   value="<?= $search ?? '' ?>" style="margin-bottom: 0;">
        </div>
        <div>
            <label for="category">Category</label>
            <select id="category" name="category" style="margin-bottom: 0;">
                <option value="">All Categories</option>
                <?php foreach ($categoryCounts as $cat): ?>
                    <option value="<?= $cat['category'] ?>"
                            <?= ($category ?? '') === $cat['category'] ? 'selected' : '' ?>>
                        <?= ucfirst($cat['category']) ?> (<?= $cat['count'] ?>)
                    </option>
                <?php endforeach; ?>
            </select>
        </div>
        <button type="submit" class="btn btn-primary" style="margin-bottom: 0;">Filter</button>
    </form>
</div>

<?php if ($search): ?>
    <div class="alert alert-success">
        Showing results for: <strong><?= $search ?></strong>
        — <a href="/notes">Clear search</a>
    </div>
<?php endif; ?>

<!-- Notes List -->
<div class="card">
    <?php if (empty($notes)): ?>
        <p style="text-align: center; color: #586069; padding: 2rem;">
            No notes found. <a href="/notes/create">Create your first note</a>.
        </p>
    <?php else: ?>
        <?php foreach ($notes as $note): ?>
        <div style="padding: 1rem; border-bottom: 1px solid #e1e4e8; <?= $note['is_pinned'] ? 'background: #fffbdd;' : '' ?>">
            <div style="display: flex; justify-content: space-between; align-items: start;">
                <div>
                    <?php if ($note['is_pinned']): ?>
                        <span style="color: #735c0f; font-size: 0.8rem;">📌 Pinned</span>
                    <?php endif; ?>
                    <h3 style="margin: 0.25rem 0;">
                        <a href="/notes/<?= $note['id'] ?>" style="color: #0366d6; text-decoration: none;">
                            <?= $note['title'] ?>
                        </a>
                    </h3>
                    <p style="color: #586069; margin: 0.25rem 0; font-size: 0.9rem;">
                        <?= mb_substr($note['content'], 0, 150) ?>
                        <?= mb_strlen($note['content']) > 150 ? '...' : '' ?>
                    </p>
                </div>
                <span class="badge badge-<?= $note['category'] === 'urgent' ? 'low' : 'active' ?>">
                    <?= ucfirst($note['category']) ?>
                </span>
            </div>
            <div style="font-size: 0.8rem; color: #959da5; margin-top: 0.5rem;">
                By <?= $note['author_name'] ?> · <?= date('M j, Y g:ia', strtotime($note['created_at'])) ?>
            </div>
        </div>
        <?php endforeach; ?>
    <?php endif; ?>
</div>

<?php
$content = ob_get_clean();
require __DIR__ . '/layout.php';
?>
